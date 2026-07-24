package core

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// ==================== 公开错误码（内部错误→公开错误的映射） ====================

const (
	AuthErrNone              uint32 = 0
	AuthErrInvalidFormat     uint32 = 1
	AuthErrSignatureInvalid  uint32 = 2
	AuthErrExpired           uint32 = 3
	AuthErrTrialExpired      uint32 = 4
	AuthErrLicenseFileMissing uint32 = 5
	AuthErrLicenseExpired    uint32 = 6
	AuthErrDeviceMismatch    uint32 = 7
	AuthErrTrialTampered     uint32 = 8
	AuthErrTimeTampered      uint32 = 9
)

const (
	PublicErrNone         uint32 = 0
	PublicErrInvalid     uint32 = 1
	PublicErrExpired     uint32 = 2
	PublicErrDeviceMismatch uint32 = 3
	PublicErrTampered    uint32 = 4
	PublicErrUnavailable uint32 = 5
)

func MapErrorCode(internalCode uint32) uint32 {
	switch internalCode {
	case AuthErrNone:
		return PublicErrNone
	case AuthErrInvalidFormat, AuthErrSignatureInvalid:
		return PublicErrInvalid
	case AuthErrExpired, AuthErrTrialExpired, AuthErrLicenseFileMissing, AuthErrLicenseExpired:
		return PublicErrExpired
	case AuthErrDeviceMismatch:
		return PublicErrDeviceMismatch
	case AuthErrTrialTampered, AuthErrTimeTampered:
		return PublicErrTampered
	default:
		return PublicErrUnavailable
	}
}

// ==================== API 注册 ====================

func RegisterAPIServer(mux *http.ServeMux, options APIOptions) {
	mux.HandleFunc("/health", CORSHandler(Health, options))
	mux.HandleFunc("/api/machinecode", CORSHandler(MachineCode(options), options))
	mux.HandleFunc("/api/watchlist", CORSHandler(WatchListHandler(options), options))
	mux.HandleFunc("/api/kline", CORSHandler(KLineHandler, options))
	mux.HandleFunc("/api/minute", CORSHandler(MinuteHandler, options))
	mux.HandleFunc("/api/realtime", CORSHandler(RealtimeHandler, options))
	mux.HandleFunc("/api/flowcapital", CORSHandler(FlowCapitalHandler, options))
	mux.HandleFunc("/api/datasource", CORSHandler(DataSourceHandler, options))
	mux.HandleFunc("/api/search", CORSHandler(SearchHandler, options))
}

func CORSHandler(h http.HandlerFunc, options APIOptions) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := options.AllowedOrigin
		if allowed == "" {
			allowed = "http://localhost"
		}
		if origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", allowed)
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Zen-Token")
		if r.Method == "OPTIONS" {
			return
		}
		if options.AuthToken != "" {
			reqToken := r.Header.Get("X-Zen-Token")
			if reqToken == "" {
				reqToken = r.URL.Query().Get("token")
			}
			if reqToken != options.AuthToken {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}
		}
		h(w, r)
	}
}

func Health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok", "timestamp": time.Now().Format(time.RFC3339)})
}

func MachineCode(options APIOptions) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		code := ""
		if options.MachineCode != nil {
			code = options.MachineCode()
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"machine_code": code})
	}
}

func WatchListHandler(options APIOptions) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if options.WatchListPath == "" {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "message": "WatchListPath not configured"})
			return
		}

		if r.Method == "POST" {
			var req struct {
				WatchSymbolsMap map[string][]string `json:"WatchSymbolsMap"`
			}
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "message": "Invalid request: " + err.Error()})
				return
			}

			data, err := json.Marshal(req.WatchSymbolsMap)
			if err != nil {
				json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "message": "Failed to marshal: " + err.Error()})
				return
			}

			if err := os.WriteFile(options.WatchListPath, data, 0600); err != nil {
				json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "message": "Failed to save: " + err.Error()})
				return
			}
			json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
			return
		}

		// GET - load watchlist
		if b, err := os.ReadFile(options.WatchListPath); err == nil {
			var watchMap map[string][]string
			if err := json.Unmarshal(b, &watchMap); err == nil {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(map[string]interface{}{"success": true, "WatchSymbolsMap": watchMap})
				return
			}
		}

		// File not exist - 创建默认 watchlist 文件
		defaultMap := map[string][]string{
			"自选股1": {"000001.SH"},
		}
		if defaultData, err := json.MarshalIndent(defaultMap, "", "  "); err == nil {
			if err := os.WriteFile(options.WatchListPath, defaultData, 0600); err != nil {
				if options.DebugMode {
					fmt.Printf("[zen_desktop] 创建 watchlist 文件失败: %v, 路径: %s\n", err, options.WatchListPath)
				}
			} else if options.DebugMode {
				fmt.Printf("[zen_desktop] 已创建默认 watchlist 文件: %s\n", options.WatchListPath)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{"success": true, "WatchSymbolsMap": defaultMap})
	}
}

func KLineHandler(w http.ResponseWriter, r *http.Request) {
	s := r.URL.Query().Get("symbol")
	if s == "" {
		fmt.Fprint(w, `{"error":"missing symbol"}`)
		return
	}

	volMul := 100.0
	if IsHK(s) {
		volMul = 1
	}

	c := 200
	if n, _ := strconv.Atoi(r.URL.Query().Get("count")); n > 0 {
		c = n
	}

	p := r.URL.Query().Get("period")
	periodStr := "day"
	isMinute := false
	switch p {
	case "1":
		periodStr = "week"
	case "2":
		periodStr = "month"
	case "5":
		periodStr = "m5"
		isMinute = true
	case "6":
		periodStr = "m15"
		isMinute = true
	case "7":
		periodStr = "m30"
		isMinute = true
	case "8":
		periodStr = "m60"
		isMinute = true
	}

	ss := Sym(s)
	var u string
	if isMinute {
		u = fmt.Sprintf("https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=%s,%s,,%d", ss, periodStr, c)
	} else {
		u = fmt.Sprintf("https://web.ifzq.gtimg.cn/appstock/app/newkline/newkline?param=%s,%s,,,%d", ss, periodStr, c)
	}

	b := GetWithGBKDecode(u)
	if b == nil {
		fmt.Fprint(w, `{"error":"fetch failed"}`)
		return
	}

	res := R{Symbol: s, Data: []KLine{}}

	if isMinute {
		var response struct {
			Code int `json:"code"`
			Data map[string]struct {
				Qt   map[string]string `json:"qt"`
				Prec string            `json:"prec"`
				M5   []interface{}     `json:"m5"`
				M15  []interface{}     `json:"m15"`
				M30  []interface{}     `json:"m30"`
				M60  []interface{}     `json:"m60"`
			} `json:"data"`
		}
		json.Unmarshal(b, &response)

		if response.Code != 0 {
			json.NewEncoder(w).Encode(res)
			return
		}
		data, ok := response.Data[ss]
		if !ok {
			json.NewEncoder(w).Encode(res)
			return
		}
		if qt, ok := data.Qt[ss]; ok {
			res.Name = qt
		}
		var yclose float64
		if prec, err := strconv.ParseFloat(data.Prec, 64); err == nil {
			yclose = prec
		}
		var minuteData []interface{}
		switch periodStr {
		case "m5":
			minuteData = data.M5
		case "m15":
			minuteData = data.M15
		case "m30":
			minuteData = data.M30
		case "m60":
			minuteData = data.M60
		}

		if minuteData != nil {
			for _, item := range minuteData {
				arr, ok := item.([]interface{})
				if !ok || len(arr) < 5 {
					continue
				}
				ts := fmt.Sprintf("%v", arr[0])
				var date, tm int
				if len(ts) >= 10 {
					date, _ = strconv.Atoi(ts[:8])
					tm, _ = strconv.Atoi(ts[8:12])
				} else {
					date, _ = strconv.Atoi(ts)
				}
				open, _ := strconv.ParseFloat(fmt.Sprintf("%v", arr[1]), 64)
				closeValue, _ := strconv.ParseFloat(fmt.Sprintf("%v", arr[2]), 64)
				high, _ := strconv.ParseFloat(fmt.Sprintf("%v", arr[3]), 64)
				low, _ := strconv.ParseFloat(fmt.Sprintf("%v", arr[4]), 64)
				vol, _ := strconv.ParseFloat(fmt.Sprintf("%v", arr[5]), 64)

				res.Data = append(res.Data, KLine{
					Date:   date,
					Time:   tm,
					YClose: yclose,
					Open:   open,
					Close:  closeValue,
					High:   high,
					Low:    low,
					Vol:    vol * volMul,
				})
				yclose = closeValue
			}
		}
	} else {
		var response struct {
			Code int `json:"code"`
			Data map[string]struct {
				Day   [][]interface{}      `json:"day"`
				Week  [][]interface{}      `json:"week"`
				Month [][]interface{}      `json:"month"`
				Qt    map[string][]string `json:"qt"`
			} `json:"data"`
		}
		json.Unmarshal(b, &response)

		if response.Code != 0 {
			writeJSON(w, res)
			return
		}
		d, ok := response.Data[ss]
		if !ok {
			writeJSON(w, res)
			return
		}

		var periodData [][]interface{}
		switch periodStr {
		case "week":
			periodData = d.Week
		case "month":
			periodData = d.Month
		default:
			periodData = d.Day
		}

		toString := func(v interface{}) string {
			if v == nil {
				return ""
			}
			return fmt.Sprintf("%v", v)
		}

		var yc float64
		for _, line := range periodData {
			if len(line) < 6 {
				continue
			}
			ds := strings.ReplaceAll(toString(line[0]), "-", "")
			date, _ := strconv.Atoi(ds)
			o, _ := strconv.ParseFloat(toString(line[1]), 64)
			c2, _ := strconv.ParseFloat(toString(line[2]), 64)
			h, _ := strconv.ParseFloat(toString(line[3]), 64)
			l, _ := strconv.ParseFloat(toString(line[4]), 64)
			v, _ := strconv.ParseFloat(toString(line[5]), 64)
			var turnover float64
			if len(line) > 8 {
				turnover, _ = strconv.ParseFloat(toString(line[8]), 64)
			} else if len(line) > 7 {
				turnover, _ = strconv.ParseFloat(toString(line[7]), 64)
			}
			res.Data = append(res.Data, KLine{Date: date, YClose: yc, Open: o, Close: c2, High: h, Low: l, Vol: v * volMul, Turnover: turnover})
			yc = c2
		}
		if qt, ok := d.Qt[ss]; ok && len(qt) > 1 {
			res.Name = qt[1]
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

func MinuteHandler(w http.ResponseWriter, r *http.Request) {
	s := r.URL.Query().Get("symbol")
	if s == "" {
		fmt.Fprint(w, `{"error":"missing symbol"}`)
		return
	}

	// date 参数：PopMinuteChart 双击历史 K 线时传入的指定日期（YYYYMMDD）。
	// 注意：腾讯 web.ifzq.gtimg.cn/appstock/app/minute/query 接口不支持历史日期查询，
	// 即使传 date 参数也始终返回当日分时数据。这里透传 date 是为了：
	// 1) 让请求链路完整，未来切换到支持历史分时的数据源时只需改这里
	// 2) 不影响当前行为（腾讯会忽略 date 参数）
	date := r.URL.Query().Get("date")

	volMul := 100.0
	if IsHK(s) {
		volMul = 1
	}

	ss := Sym(s)
	u := fmt.Sprintf("https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=%s", ss)
	if date != "" {
		u += "&date=" + date
	}

	b := GetWithGBKDecode(u)
	if b == nil {
		fmt.Fprint(w, `{"error":"fetch failed"}`)
		return
	}

	var qq struct {
		Code int `json:"code"`
		Data map[string]struct {
			Data struct {
				Date int      `json:"date"`
				Data []string `json:"data"`
			} `json:"data"`
			Qt map[string][]string `json:"qt"`
		} `json:"data"`
	}
	json.Unmarshal(b, &qq)

	res := R{Symbol: s}
	if qq.Code == 0 {
		if d, ok := qq.Data[ss]; ok {
			date := d.Data.Date
			for _, line := range d.Data.Data {
				parts := strings.Split(line, " ")
				if len(parts) < 4 {
					continue
				}
				tm, _ := strconv.Atoi(parts[0])
				price, _ := strconv.ParseFloat(parts[1], 64)
				vol, _ := strconv.ParseFloat(parts[2], 64)
				res.Data = append(res.Data, KLine{Date: date, Time: tm, Price: price, Vol: vol * volMul})
			}
			if qt, ok := d.Qt[ss]; ok && len(qt) > 4 {
				res.Name = qt[1]
				if yc, err := strconv.ParseFloat(qt[4], 64); err == nil {
					if len(res.Data) > 0 {
						res.Data[0].YClose = yc
					}
				}
			}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

func RealtimeHandler(w http.ResponseWriter, r *http.Request) {
	s := r.URL.Query().Get("symbol")
	if s == "" {
		fmt.Fprint(w, `{"error":"missing symbol"}`)
		return
	}

	ss := SymRealtime(s)
	u := fmt.Sprintf("https://sqt.gtimg.cn/?q=%s&fmt=json&app=wzq&t=%d", ss, time.Now().UnixNano()/1e6)

	b := GetWithGBKDecode(u)
	if b == nil {
		fmt.Fprint(w, `{"error":"fetch failed"}`)
		return
	}

	var qq map[string][]string
	json.Unmarshal(b, &qq)

	res := R{Symbol: s}
	if qq == nil {
		res.Error = "invalid response"
	} else if d, ok := qq[ss]; !ok || len(d) <= 30 {
		res.Error = "not found"
	} else {
		if len(d) > 1 {
			res.Name = d[1]
		}
		p := func(i int) float64 {
			v, _ := strconv.ParseFloat(d[i], 64)
			return v
		}
		vol := p(6)
		if !IsHK(s) {
			vol *= 100
		}
		res.Data = append(res.Data, KLine{
			Close: p(3), YClose: p(4), Open: p(5), High: p(33), Low: p(34), Vol: vol,
		})
	}
	writeJSON(w, res)
}

func FlowCapitalHandler(w http.ResponseWriter, r *http.Request) {
	s := r.URL.Query().Get("symbol")
	if s == "" {
		fmt.Fprint(w, `{"error":"missing symbol"}`)
		return
	}

	ss := SymRealtime(s)
	u := fmt.Sprintf("https://sqt.gtimg.cn/?q=%s&fmt=json&app=wzq&t=%d", ss, time.Now().UnixNano()/1e6)

	b := GetWithGBKDecode(u)
	if b == nil {
		fmt.Fprint(w, `{"error":"fetch failed"}`)
		return
	}

	var qq map[string][]string
	json.Unmarshal(b, &qq)

	res := R{Symbol: s}
	if qq != nil {
		if d, ok := qq[ss]; ok && len(d) > 30 {
			if len(d) > 38 {
				if fc, err := strconv.ParseFloat(d[38], 64); err == nil {
					res.FlowCapital = int(fc * 10000)
				}
			}
			if len(d) > 1 {
				res.Name = d[1]
			}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

type SearchResult struct {
	Market string `json:"market"`
	Code   string `json:"code"`
	Name   string `json:"name"`
	Pinyin string `json:"pinyin"`
	Type   string `json:"type"`
}

type SearchResponse struct {
	Success bool           `json:"success"`
	Results []SearchResult `json:"results"`
	Error   string         `json:"error,omitempty"`
}

func SearchHandler(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" || len(q) > 50 {
		writeJSON(w, SearchResponse{Success: true, Results: []SearchResult{}})
		return
	}

	encodedQ := url.QueryEscape(q)
	apiUrl := fmt.Sprintf("https://smartbox.gtimg.cn/s3/?v=2&q=%s&t=all&c=1", encodedQ)
	body := GetWithUTF8(apiUrl)
	if body == nil {
		writeJSON(w, SearchResponse{Success: false, Error: "搜索请求失败"})
		return
	}

	content := string(body)
	start := strings.Index(content, `v_hint="`)
	if start == -1 {
		writeJSON(w, SearchResponse{Success: true, Results: []SearchResult{}})
		return
	}
	start += len(`v_hint="`)
	end := strings.Index(content[start:], `"`)
	if end == -1 {
		writeJSON(w, SearchResponse{Success: true, Results: []SearchResult{}})
		return
	}
	hint := content[start : start+end]

	results := []SearchResult{}
	items := strings.Split(hint, "^")
	for _, item := range items {
		parts := strings.Split(item, "~")
		if len(parts) < 5 {
			continue
		}

		market := parts[0]
		code := parts[1]
		name := decodeUnicodeEscapes(parts[2])
		pinyin := parts[3]
		stockType := parts[4]

		typeName := ""
		switch stockType {
		case "GP-A", "GP-A-KCB": //A股 / 科创板(688开头，含 000/002/300/600/601/603)
			typeName = "A股"
		case "GP-B": //B股(沪B 900xxx, 深B 200xxx)
			typeName = "B股"
		case "ZS": //沪深指数(000xxx, 399xxx)
			typeName = "指数"
		case "ETF": //场内ETF(510xxx 沪, 159xxx 深)
			typeName = "ETF"
		case "LOF": //LOF基金(16xxxxx)
			typeName = "LOF"
		case "GP":
			if market == "hk" {
				typeName = "港股"
			} else {
				continue
			}
		default:
			continue
		}

		results = append(results, SearchResult{
			Market: market,
			Code:   code,
			Name:   name,
			Pinyin: pinyin,
			Type:   typeName,
		})
	}

	writeJSON(w, SearchResponse{Success: true, Results: results})
}

func decodeUnicodeEscapes(s string) string {
	var buf strings.Builder
	buf.Grow(len(s))
	i := 0
	for i < len(s) {
		if i+5 < len(s) && s[i] == '\\' && s[i+1] == 'u' {
			hex := s[i+2 : i+6]
			if code, err := strconv.ParseInt(hex, 16, 32); err == nil {
				if utf8.ValidRune(rune(code)) {
					buf.WriteRune(rune(code))
					i += 6
					continue
				}
			}
		}
		buf.WriteByte(s[i])
		i++
	}
	return buf.String()
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	data, err := json.Marshal(v)
	if err != nil {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(`{"success":false,"error":"JSON编码失败"}`))
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(data)
}

func DataSourceHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "GET" {
		cfg := GetDataSourceConfig()
		if cfg == nil {
			json.NewEncoder(w).Encode(map[string]interface{}{"error": "not initialized"})
			return
		}
		json.NewEncoder(w).Encode(map[string]interface{}{
			"active":  cfg.Active,
			"sources": cfg.Sources,
		})
		return
	}

	if r.Method == "POST" {
		var req struct {
			Active string `json:"active"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "error": "invalid request"})
			return
		}
		if req.Active == "" {
			json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "error": "active is empty"})
			return
		}
		if err := SetActiveDataSource(req.Active); err != nil {
			json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "error": err.Error()})
			return
		}
		json.NewEncoder(w).Encode(map[string]interface{}{"success": true, "active": req.Active})
		return
	}
}
