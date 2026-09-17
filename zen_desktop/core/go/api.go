package core

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// maxBodyBytes 限制 HTTP 请求体大小，防止恶意超大请求耗尽内存
const maxBodyBytes = 1 << 20 // 1MB

// ==================== 公开错误码（内部错误→公开错误的映射） ====================
//
// 内部错误码必须与 Rust AuthErrorCode 枚举值（src/auth/error_codes.rs）保持一致。
// Helper 返回的 error_code 字段直接使用 Rust 枚举值序列化，不可重新编号。

const (
	AuthErrNone               uint32 = 0  // AuthErrorCode::None
	AuthErrInvalidFormat      uint32 = 1  // AuthErrorCode::InvalidFormat
	AuthErrSignatureInvalid   uint32 = 2  // AuthErrorCode::SignatureInvalid
	AuthErrExpired            uint32 = 3  // AuthErrorCode::Expired
	AuthErrDeviceMismatch     uint32 = 4  // AuthErrorCode::DeviceMismatch
	AuthErrTrialExpired       uint32 = 5  // AuthErrorCode::TrialExpired
	AuthErrTrialTampered      uint32 = 6  // AuthErrorCode::TrialTampered
	AuthErrTimeTampered       uint32 = 7  // AuthErrorCode::TimeTampered
	AuthErrNetworkTimeFailed  uint32 = 8  // AuthErrorCode::NetworkTimeFailed
	AuthErrNetworkUnavailable uint32 = 9  // AuthErrorCode::NetworkUnavailable
	AuthErrStorageUnavailable uint32 = 10 // AuthErrorCode::StorageUnavailable
	AuthErrUnknown            uint32 = 11 // AuthErrorCode::Unknown
	AuthErrLicenseFileMissing uint32 = 12 // AuthErrorCode::LicenseFileMissing
	AuthErrLicenseExpired     uint32 = 13 // AuthErrorCode::LicenseExpired
)

const (
	PublicErrNone              uint32 = 0
	PublicErrInvalid           uint32 = 1
	PublicErrExpired           uint32 = 2
	PublicErrDeviceMismatch    uint32 = 3
	PublicErrTampered          uint32 = 4
	PublicErrNetworkTimeFailed  uint32 = 5
	PublicErrNetworkUnavailable uint32 = 8 // 跳过6/7（前端虚拟码：6=后台已退出, 7=网络错误）
	PublicErrStorageUnavailable uint32 = 9
	PublicErrUnknown            uint32 = 11 // 与 Rust AuthErrorCode::Unknown 对齐
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
	case AuthErrNetworkTimeFailed:
		return PublicErrNetworkTimeFailed
	case AuthErrNetworkUnavailable:
		return PublicErrNetworkUnavailable
	case AuthErrStorageUnavailable:
		return PublicErrStorageUnavailable
	default:
		return PublicErrUnknown
	}
}

// ==================== JSON interface{} 快速提取 ====================
//
// 腾讯行情经 encoding/json 解析到 interface{} 后，数值字段为 float64、
// 日期字段为 string。热路径逐根 K 线解析时用类型断言直接提取，
// 避免 fmt.Sprintf（反射+格式化+分配）再 ParseFloat 的字符串往返开销。

// ifaceStr 从 JSON interface{} 提取字符串（日期/时间戳字段）
func ifaceStr(v interface{}) string {
	switch x := v.(type) {
	case string:
		return x
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", v)
	}
}

// ifaceF64 从 JSON interface{} 提取 float64（价格/成交量字段）
func ifaceF64(v interface{}) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case string:
		f, _ := strconv.ParseFloat(x, 64)
		return f
	case nil:
		return 0
	default:
		f, _ := strconv.ParseFloat(fmt.Sprintf("%v", v), 64)
		return f
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
	mux.HandleFunc("/api/zenconfig", CORSHandler(ZenConfigHandler, options))
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
			r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
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

	enddate := r.URL.Query().Get("enddate")

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

	// 转换 enddate 格式：
	// 日线：YYYYMMDD → YYYY-MM-DD（腾讯 newkline 要求带横杠）
	// 分钟线：YYYYMMDDHHMM 直接使用（腾讯 mkline 的 param=symbol,period,enddatetime,count）
	endDateForAPI := ""
	if enddate != "" {
		if isMinute {
			endDateForAPI = enddate // YYYYMMDDHHMM
		} else if len(enddate) >= 8 {
			endDateForAPI = enddate[:4] + "-" + enddate[4:6] + "-" + enddate[6:8]
		}
	}

	ss := Sym(s)
	// 腾讯 newkline/fqkline 单次请求硬上限 2000 根（实测 2000 成功、2100 返回空 data）。
	// 日/周/月线 count>2000 时分段拉取拼接：
	//   第一段 newkline（最新数据，时间升序），后续段 fqkline 以 end=已获取最早日期
	//   向更早分页（fqkline 的 end 含当日，拼接时按日期去重；末项空=不复权，与 newkline 口径一致）
	const tencentSegLimit = 2000
	fetchSegment := func(endYYYYMMDD string, n int) ([][]interface{}, string) {
		var su string
		if n > tencentSegLimit {
			n = tencentSegLimit
		}
		if endYYYYMMDD == "" {
			if endDateForAPI != "" {
				su = fmt.Sprintf("https://web.ifzq.gtimg.cn/appstock/app/newkline/newkline?param=%s,%s,,%s,%d", ss, periodStr, endDateForAPI, n)
			} else {
				su = fmt.Sprintf("https://web.ifzq.gtimg.cn/appstock/app/newkline/newkline?param=%s,%s,,,%d", ss, periodStr, n)
			}
		} else {
			ed := endYYYYMMDD[:4] + "-" + endYYYYMMDD[4:6] + "-" + endYYYYMMDD[6:8]
			su = fmt.Sprintf("https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=%s,%s,,%s,%d,", ss, periodStr, ed, n)
		}
		sb := GetWithGBKDecode(su)
		if sb == nil {
			return nil, ""
		}
		var resp struct {
			Code int `json:"code"`
			Data map[string]struct {
				Day   [][]interface{}     `json:"day"`
				Week  [][]interface{}     `json:"week"`
				Month [][]interface{}     `json:"month"`
				Qt    map[string][]string `json:"qt"`
			} `json:"data"`
		}
		json.Unmarshal(sb, &resp)
		if resp.Code != 0 {
			return nil, ""
		}
		d, ok := resp.Data[ss]
		if !ok {
			return nil, ""
		}
		name := ""
		if qt, ok := d.Qt[ss]; ok && len(qt) > 1 {
			name = qt[1]
		}
		switch periodStr {
		case "week":
			return d.Week, name
		case "month":
			return d.Month, name
		default:
			return d.Day, name
		}
	}
	var b []byte
	if isMinute {
		var u string
		if c > 800 {
			c = 800
		}
		if endDateForAPI != "" {
			u = fmt.Sprintf("https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=%s,%s,%s,%d", ss, periodStr, endDateForAPI, c)
		} else {
			u = fmt.Sprintf("https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=%s,%s,,%d", ss, periodStr, c)
		}
		b = GetWithGBKDecode(u)
		if b == nil {
			fmt.Fprint(w, `{"error":"fetch failed"}`)
			return
		}
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

		for _, item := range minuteData {
			arr, ok := item.([]interface{})
			if !ok || len(arr) < 5 {
				continue
			}
			ts := ifaceStr(arr[0])
			var date, tm int
			if len(ts) >= 10 {
				date, _ = strconv.Atoi(ts[:8])
				tm, _ = strconv.Atoi(ts[8:12])
			} else {
				date, _ = strconv.Atoi(ts)
			}
			open := ifaceF64(arr[1])
			closeValue := ifaceF64(arr[2])
			high := ifaceF64(arr[3])
			low := ifaceF64(arr[4])
			vol := ifaceF64(arr[5])

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
	} else {
		// 分段拉取拼接（见 fetchSegment 注释）：第一段 newkline 最新数据，
		// 后续段 fqkline 以 end=已获取最早日期向更早翻页，直到拿满 count 或无更多历史
		var all [][]interface{}
		stockName := ""
		segEnd := ""
		for len(all) < c {
			want := c - len(all)
			if want > tencentSegLimit {
				want = tencentSegLimit
			}
			seg, segName := fetchSegment(segEnd, want)
			if segName != "" {
				stockName = segName
			}
			if len(seg) == 0 {
				break
			}
			segFull := len(seg) >= want // 满段判断须在去重前（去重后少1根会误判数据尽头）
			if segEnd == "" {
				all = seg
			} else {
				// fqkline 的 end 含当日：seg 尾部可能与 all 头部日期重复，按日期去重
				earliest := ifaceStr(all[0][0])
				drop := 0
				for i := len(seg) - 1; i >= 0; i-- {
					if ifaceStr(seg[i][0]) == earliest {
						drop++
					} else {
						break
					}
				}
				seg = seg[:len(seg)-drop]
				if len(seg) == 0 {
					break
				}
				all = append(seg, all...)
			}
			if !segFull {
				break // 不满段 = 已到数据尽头
			}
			// 下一段 end = 当前最早日期（YYYYMMDD，去横杠）
			segEnd = strings.ReplaceAll(ifaceStr(all[0][0]), "-", "")
		}

		var yc float64
		for _, line := range all {
			if len(line) < 6 {
				continue
			}
			ds := strings.ReplaceAll(ifaceStr(line[0]), "-", "")
			date, _ := strconv.Atoi(ds)
			o := ifaceF64(line[1])
			c2 := ifaceF64(line[2])
			h := ifaceF64(line[3])
			l := ifaceF64(line[4])
			v := ifaceF64(line[5])
			var turnover float64
			if len(line) > 8 {
				turnover = ifaceF64(line[8])
			} else if len(line) > 7 {
				turnover = ifaceF64(line[7])
			}
			res.Data = append(res.Data, KLine{Date: date, YClose: yc, Open: o, Close: c2, High: h, Low: l, Vol: v * volMul, Turnover: turnover})
			yc = c2
		}
		res.Name = stockName
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

// realtimeQuoteCache 合并 Realtime/FlowCapital 对同一 symbol 的重复上游请求：
// 两者请求同一腾讯接口，前端常在同一周期内先后调用。TTL 内直接复用响应体
// （响应只读，两个 handler 均只做 json.Unmarshal），显著减少上游请求次数。
var realtimeQuoteCache sync.Map // ss -> realtimeCacheEntry

type realtimeCacheEntry struct {
	at   time.Time
	data []byte
}

const realtimeCacheTTL = time.Second

// fetchRealtimeQuote 拉取实时行情快照（1 秒 TTL 共享缓存）
func fetchRealtimeQuote(ss string) []byte {
	now := time.Now()
	if v, ok := realtimeQuoteCache.Load(ss); ok {
		if e, ok := v.(realtimeCacheEntry); ok && now.Sub(e.at) < realtimeCacheTTL {
			return e.data
		}
	}
	u := fmt.Sprintf("https://sqt.gtimg.cn/?q=%s&fmt=json&app=wzq&t=%d", ss, now.UnixNano()/1e6)
	b := GetWithGBKDecode(u)
	if b == nil {
		return nil
	}
	realtimeQuoteCache.Store(ss, realtimeCacheEntry{at: now, data: b})
	return b
}

func RealtimeHandler(w http.ResponseWriter, r *http.Request) {
	s := r.URL.Query().Get("symbol")
	if s == "" {
		fmt.Fprint(w, `{"error":"missing symbol"}`)
		return
	}

	ss := SymRealtime(s)

	b := fetchRealtimeQuote(ss)
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

	b := fetchRealtimeQuote(ss)
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
			"active":    cfg.Active,
			"sources":   cfg.Sources,
			"zenConfig": cfg.ZenConfig,
		})
		return
	}

	if r.Method == "POST" {
		var req struct {
			Active string `json:"active"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
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

// ZenConfigHandler 处理缠论配置的读写（GET 读取，POST 保存）
func ZenConfigHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "GET" {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"zenConfig": GetZenConfig(),
		})
		return
	}

	if r.Method == "POST" {
		var req struct {
			ZenConfig map[string]interface{} `json:"zenConfig"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "error": "invalid request"})
			return
		}
		SetZenConfig(req.ZenConfig)
		json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
		return
	}
}