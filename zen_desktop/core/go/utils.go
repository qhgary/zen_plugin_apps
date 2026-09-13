package core

import (
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

var gbkClient = &http.Client{
	Transport: &http.Transport{
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   20,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   2 * time.Second,
		ResponseHeaderTimeout: 2 * time.Second,
		DialContext: (&net.Dialer{
			Timeout:   2 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
	},
	Timeout: 3 * time.Second,
}

func GetWithGBKDecode(url string) []byte {
	resp, err := gbkClient.Get(url)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil
	}

	decoder := simplifiedchinese.GBK.NewDecoder()
	utf8Body, _, err := transform.Bytes(decoder, body)
	if err != nil {
		return body
	}

	return utf8Body
}

func GetWithUTF8(url string) []byte {
	resp, err := gbkClient.Get(url)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil
	}

	return body
}

func Sym(s string) string {
	if s == "" {
		return ""
	}

	upper := strings.ToUpper(s)

	if strings.HasSuffix(upper, ".SH") {
		return "sh" + upper[:len(upper)-3]
	}
	if strings.HasSuffix(upper, ".SZ") {
		return "sz" + upper[:len(upper)-3]
	}
	if strings.HasSuffix(upper, ".BJ") {
		return "bj" + upper[:len(upper)-3]
	}
	if strings.HasSuffix(upper, ".HK") {
		return "hk" + upper[:len(upper)-3]
	}

	if strings.Contains(upper, ".") {
		parts := strings.Split(upper, ".")
		if len(parts) >= 2 {
			switch {
			case strings.HasPrefix(parts[1], "SH"):
				return "sh" + parts[0]
			case strings.HasPrefix(parts[1], "SZ"):
				return "sz" + parts[0]
			case strings.HasPrefix(parts[1], "BJ"):
				return "bj" + parts[0]
			case strings.HasPrefix(parts[1], "HK"):
				return "hk" + parts[0]
			}
		}
	}

	if strings.HasPrefix(upper, "SH") || strings.HasPrefix(upper, "SZ") {
		return strings.ToLower(upper)
	}
	if strings.HasPrefix(upper, "BJ") {
		return strings.ToLower(upper)
	}
	if strings.HasPrefix(upper, "HK") {
		return "hk" + upper[2:]
	}

	if len(upper) == 6 {
		if strings.HasPrefix(upper, "6") || strings.HasPrefix(upper, "9") {
			return "sh" + upper
		}
		if strings.HasPrefix(upper, "4") || strings.HasPrefix(upper, "8") {
			return "bj" + upper
		}
		return "sz" + upper
	}

	return strings.ToLower(upper)
}

func SymRealtime(s string) string {
	sym := Sym(s)
	if strings.HasPrefix(sym, "hk") {
		return "r_" + sym
	}
	return sym
}

func IsHK(s string) bool {
	upper := strings.ToUpper(s)
	return strings.HasSuffix(upper, ".HK") || strings.HasPrefix(upper, "HK") || strings.HasPrefix(Sym(s), "hk")
}
