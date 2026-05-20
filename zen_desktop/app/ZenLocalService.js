// Zen 本地数据服务 - 指向本地Go代理服务器
(function() {
    // 自动探测端口和地址，支持动态分配的端口
    var API_BASE = window.location.origin || (window.location.protocol + "//" + window.location.host);
    var REQUEST_RETRY_MS = 1000;
    var REQUEST_MAX_RETRIES = 5;

    function sleep(ms) {
        return new Promise(function(resolve) {
            setTimeout(resolve, ms);
        });
    }

    function hasNonEmptyData(response) {
        return !!(response && Array.isArray(response.Data) && response.Data.length > 0);
    }

    async function fetchJsonWithRetry(url, label, validate) {
        var token = new URLSearchParams(window.location.search).get('token') || '';
        var headers = token ? {'X-Zen-Token': token} : {};
        for (var attempt = 0; attempt < REQUEST_MAX_RETRIES; attempt++) {
            try {
                var response = await fetch(url, { cache: "no-store", headers: headers });
                if (!response.ok) throw new Error("HTTP " + response.status);

                var json = await response.json();
                if (json && !json.error && (!validate || validate(json))) return json;

                throw new Error(json && json.error ? json.error : "响应数据未就绪");
            } catch (e) {
                if (attempt < REQUEST_MAX_RETRIES - 1) {
                    console.warn("[ZenLocalService] " + label + " 获取失败 (尝试 " + (attempt+1) + "/" + REQUEST_MAX_RETRIES + "), 1秒后重试:", e);
                    await sleep(REQUEST_RETRY_MS);
                } else {
                    console.error("[ZenLocalService] " + label + " 最终失败:", e);
                    throw e;
                }
            }
        }
    }

    var ZenSvc = {
        async kline(sym, p, c) {
            var url = API_BASE + "/api/kline?symbol=" + sym + "&period=" + p + "&count=" + (c||200);
            return await fetchJsonWithRetry(url, "K线[" + sym + "]", hasNonEmptyData);
        },
        async minute(sym) {
            var url = API_BASE + "/api/minute?symbol=" + sym + "&count=500";
            return await fetchJsonWithRetry(url, "分时[" + sym + "]", hasNonEmptyData);
        },
        async realtime(sym) {
            var url = API_BASE + "/api/realtime?symbol=" + sym;
            return await fetchJsonWithRetry(url, "实时[" + sym + "]", hasNonEmptyData);
        },
        async flowcapital(sym) {
            var url = API_BASE + "/api/flowcapital?symbol=" + sym;
            return await fetchJsonWithRetry(url, "流通股本[" + sym + "]", function(response) {
                return !!(response && typeof response.FlowCapital === "number");
            });
        },
        async getLicenseInfo() {
            try {
                var token = new URLSearchParams(window.location.search).get('token') || '';
                var headers = token ? {'X-Zen-Token': token} : {};
                var j = await (await fetch(API_BASE + "/api/auth/status", { cache: "no-store", headers: headers })).json();
                return j;
            } catch(e) {
                return { machine_code: "" };
            }
        }
    };

    // 构建分钟K线数据用于迷你图
    function buildMinuteKLine(minuteData) {
        if (!minuteData || !minuteData.Data || minuteData.Data.length === 0) return null;
        var aryClose = [];
        var yclose = 0;
        for (var i = 0; i < minuteData.Data.length; i++) {
            var item = minuteData.Data[i];
            if (item.Price) {
                aryClose.push(item.Price);
                if (i === 0 && item.YClose) yclose = item.YClose;
            }
        }
        return { AryClose: aryClose, YClose: yclose || 0 };
    }

    // 构建股票数据项
    function buildStockItem(r, type) {
        var itemData = r.Data || [];
        var yclose = (itemData.length > 0) ? (itemData[0].YClose || 0) : 0;
        var close = (itemData.length > 0) ? (itemData[0].Close || 0) : 0;
        
        // Type=100/101 K线数据
        if (type === 100 || type === 101) {
            // 设置FlowCapital=true表示有换手率数据，HQChart会用换手率计算流通股本
            return { Name: r.Name || "", Data: itemData, FlowCapital: true };
        }
        
        // Type=3 分钟数据
        if (type === 3) {
            var minute = buildMinuteKLine(r);
            return { Name: r.Name || "", YClose: yclose, Data: itemData, Minute: minute };
        }
        
        // Type=1/2 实时数据 - 涨跌幅计算
        var high = (itemData.length > 0) ? (itemData[0].High || 0) : 0;
        var low = (itemData.length > 0) ? (itemData[0].Low || 0) : 0;
        var open = (itemData.length > 0) ? (itemData[0].Open || 0) : 0;
        var vol = (itemData.length > 0) ? (itemData[0].Vol || 0) : 0;
        
        var increase = 0, updown = 0, amplitude = 0;
        if (yclose > 0 && close > 0) {
            updown = close - yclose;
            increase = (updown / yclose) * 100;
            if (high > 0 && low > 0) amplitude = ((high - low) / yclose) * 100;
        }
        
        return {
            Name: r.Name || "",
            YClose: yclose,
            Close: close,
            High: high,
            Low: low,
            Open: open,
            Vol: vol,
            Increase: increase,
            UpDown: updown,
            Amplitude: amplitude,
            Data: itemData
        };
    }

    var ZenWS = {
        Request: function(m, c) {
            if (!c || !c.Callback) return;
            var d = m.Data;
            var arySymbol = d.ArySymbol || [];
            
            if (arySymbol.length === 0) { 
                c.Callback({Error:'No sym'}); 
                return; 
            }
            
            var type = d.Type;
            var promises = [];
            
            // Type=1/2 需要同时获取实时数据+分钟数据+K线数据
            if (type === 1 || type === 2) {
                for (var i = 0; i < arySymbol.length; i++) {
                    var sym = arySymbol[i].Symbol;
                    // 获取 Fields 中请求的 K 线配置
                    var fields = arySymbol[i].Fields || {};
                    var kLineConfig = fields.KLine;
                    var kLinePeriod = kLineConfig ? (kLineConfig.Period || 0) : 0;
                    var kLineCount = kLineConfig ? (kLineConfig.Count || 20) : 20;
                    
                    var p = Promise.all([
                        ZenSvc.realtime(sym),
                        ZenSvc.minute(sym),
                        // 异步获取 K 线数据（仅当请求了 KLine 字段时）
                        kLineConfig ? ZenSvc.kline(sym, kLinePeriod, kLineCount) : Promise.resolve(null)
                    ]).then(function(results) {
                        return { realtime: results[0], minute: results[1], kline: results[2] };
                    });
                    promises.push(p);
                }
            } else {
                // 其他类型直接获取
                for (var i = 0; i < arySymbol.length; i++) {
                    var sym = arySymbol[i].Symbol;
                    var period = arySymbol[i].Period;
                    var count = arySymbol[i].Count || 640;
                    
                    var p = null;
                    switch(type) {
                        case 100: case 101: 
                            p = ZenSvc.kline(sym, period||0, count); 
                            break;
                        case 3: 
                            p = ZenSvc.minute(sym); 
                            break;
                        case 200: 
                            p = ZenSvc.flowcapital(sym); 
                            break;
                    }
                    if (p) promises.push(p);
                }
            }
            
            if (promises.length === 0) {
                if (c && c.Callback) c.Callback({Error:'Unknown type'}); 
                return; 
            }
            
            Promise.all(promises).then(function(results) {
                var aryData = [];
                
                for (var i = 0; i < results.length; i++) {
                    var r = results[i];
                    var sym = arySymbol[i].Symbol;
                    
                    var stockItem;
                    if (type === 1 || type === 2) {
                        // Type=1/2: results[i] is {realtime, minute, kline}
                        var realtime = r.realtime;
                        var minute = r.minute;
                        var kline = r.kline;  // K 线数据（用于日K简图）
                        
                        var itemData = (realtime.Data || []);
                        var yclose = (itemData.length > 0) ? (itemData[0].YClose || 0) : 0;
                        var close = (itemData.length > 0) ? (itemData[0].Close || 0) : 0;
                        var high = (itemData.length > 0) ? (itemData[0].High || 0) : 0;
                        var low = (itemData.length > 0) ? (itemData[0].Low || 0) : 0;
                        var open = (itemData.length > 0) ? (itemData[0].Open || 0) : 0;
                        var vol = (itemData.length > 0) ? (itemData[0].Vol || 0) : 0;
                        
                        var updown = 0, increase = 0, amplitude = 0;
                        if (yclose > 0 && close > 0) {
                            updown = close - yclose;
                            increase = (updown / yclose) * 100;
                            if (high > 0 && low > 0) amplitude = ((high - low) / yclose) * 100;
                        }
                        
                        // 构建Minute迷你图数据
                        var minuteKLine = buildMinuteKLine(minute);
                        
                        // 构建K线迷你图数据
                        var kLineData = null;
                        if (kline && kline.Data && kline.Data.length > 0) {
                            kLineData = { Data: kline.Data };
                        }
                        
                        stockItem = {
                            Name: realtime.Name || "",
                            YClose: yclose,
                            Close: close,
                            High: high,
                            Low: low,
                            Open: open,
                            Vol: vol,
                            Increase: increase,
                            UpDown: updown,
                            Amplitude: amplitude,
                            Data: itemData,
                            Minute: minuteKLine,
                            KLine: kLineData  // 添加 K 线数据用于日K简图
                        };
                    } else {
                        stockItem = buildStockItem(r, type);
                    }
                    
                    stockItem.Symbol = sym;
                    stockItem.Code = 0;
                    aryData.push(stockItem);
                }
                
                var recv = {
                    MessageID: 2, 
                    Code: 0, 
                    AryData: aryData,
                    Data: {
                        ID: d.ID, 
                        Type: d.Type, 
                        AryData: aryData, 
                        ExtendData: d.ExtendData
                    }
                };
                
                if (c && c.Callback) c.Callback(recv.Data);
            }).catch(function(e) {
                if (c && c.Callback) c.Callback({Error:String(e)});
            });
        }
    };

    Object.defineProperty(window, 'ZenWSClient', {
        value: ZenWS,
        writable: false,
        configurable: false
    });
})();
