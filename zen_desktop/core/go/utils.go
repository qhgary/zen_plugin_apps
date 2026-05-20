package core

import (
	"io"
	"net/http"
	"strings"
	"time"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

// Shared HTTP client with connection pooling for GBK decode requests.
// Reuses TCP connections across requests, significantly reducing latency
// when fetching market data (avoids ~100-200ms per new TCP handshake).
var gbkClient = &http.Client{
	Transport: &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 20,
		IdleConnTimeout:     90 * time.Second,
	},
	Timeout: 15 * time.Second,
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


func Sym(s string) string {
	if s == "" {
		return ""
	}

	s = strings.ToUpper(s)
	if strings.HasSuffix(s, ".SH") {
		return "sh" + strings.TrimSuffix(s, ".SH")
	}
	if strings.HasSuffix(s, ".SZ") {
		return "sz" + strings.TrimSuffix(s, ".SZ")
	}

	if strings.Contains(s, ".") {
		parts := strings.Split(s, ".")
		if len(parts) >= 2 {
			if strings.HasPrefix(parts[1], "SH") {
				return "sh" + parts[0]
			} else if strings.HasPrefix(parts[1], "SZ") {
				return "sz" + parts[0]
			}
		}
	}

	if strings.HasPrefix(s, "SH") || strings.HasPrefix(s, "SZ") {
		return strings.ToLower(s)
	}

	if len(s) == 6 {
		if strings.HasPrefix(s, "6") || strings.HasPrefix(s, "9") {
			return "sh" + s
		}
		return "sz" + s
	}

	return strings.ToLower(s)
}
