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
        async kline(sym, p, c, enddate) {
            var url = API_BASE + "/api/kline?symbol=" + sym + "&period=" + p + "&count=" + (c||200);
            if (enddate) url += "&enddate=" + enddate;
            var validate = enddate ? null : hasNonEmptyData;
            return await fetchJsonWithRetry(url, "K线[" + sym + "]", validate);
        },
        async minute(sym, date) {
            var url = API_BASE + "/api/minute?symbol=" + sym + "&count=500";
            if (date) url += "&date=" + date;
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

        // Type=3 分钟数据 - 补充顶层 Date 字段（从首条分钟数据提取），避免 HQChart 标题显示 undefined
        if (type === 3) {
            var minute = buildMinuteKLine(r);
            var minuteDate = (itemData.length > 0) ? (itemData[0].Date || 0) : 0;
            return { Name: r.Name || "", Date: minuteDate, YClose: yclose, Data: itemData, Minute: minute };
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

    // 构建空数据响应，确保 HQChart 的 NetworkFilter 回调能关闭 splash
    // 关键修复：之前返回 {Error:...} 会导致 HQChart 的 RecvMinuteData 提前 return 不调 Draw()，
    // 进而 SplashPaint 中的"数据加载中"文字一直留在 Canvas 上
    function buildEmptyAryData(arySymbol, type) {
        var aryData = [];
        for (var i = 0; i < arySymbol.length; i++) {
            var sym = arySymbol[i].Symbol;
            var stockItem = { Symbol: sym, Code: 0, Name: "" };
            if (type === 100 || type === 101) {
                stockItem.Data = [];
                stockItem.FlowCapital = false;
            } else if (type === 3) {
                stockItem.Data = [];
                stockItem.YClose = 0;
            } else if (type === 200) {
                stockItem.Data = [];
            } else {
                stockItem.Data = [];
            }
            aryData.push(stockItem);
        }
        return aryData;
    }

    var ZenWS = {
        Request: function(m, c) {
            if (!c || !c.Callback) return;
            var d = m.Data;
            var arySymbol = d.ArySymbol || [];

            if (arySymbol.length === 0) {
                // 返回空数据而非 Error，确保 HQChart 关闭 splash
                c.Callback({ ID: d.ID, Type: d.Type, AryData: [], ExtendData: d.ExtendData });
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

                    var p = Promise.allSettled([
                        ZenSvc.realtime(sym),
                        ZenSvc.minute(sym),
                        // 异步获取 K 线数据（仅当请求了 KLine 字段时）
                        kLineConfig ? ZenSvc.kline(sym, kLinePeriod, kLineCount) : Promise.resolve(null)
                    ]).then(function(results) {
                        // 容错：单个子请求失败时用 null 替代，不阻断整体
                        var realtime = results[0].status === 'fulfilled' ? results[0].value : null;
                        var minute = results[1].status === 'fulfilled' ? results[1].value : null;
                        var kline = results[2].status === 'fulfilled' ? results[2].value : null;
                        return { realtime: realtime, minute: minute, kline: kline };
                    });
                    promises.push(p);
                }
            } else {
                // 其他类型直接获取
                for (var i = 0; i < arySymbol.length; i++) {
                    var sym = arySymbol[i].Symbol;
                    var period = arySymbol[i].Period;
                    var count = arySymbol[i].Count || 420;
                    var minuteDate = arySymbol[i].Date;  // PopMinuteChart 传入的指定日期
                    var enddate = arySymbol[i].Range ? arySymbol[i].Range.End : null;

                    var p = null;
                    switch(type) {
                        case 100: case 101:
                            p = ZenSvc.kline(sym, period||0, count, enddate);
                            break;
                        case 3:
                            p = ZenSvc.minute(sym, minuteDate);
                            break;
                        case 200:
                            p = ZenSvc.flowcapital(sym);
                            break;
                    }
                    if (p) {
                        // 包装为 settled 结果，单个失败不影响其他
                        (function(idx, promise) {
                            promises[idx] = promise.then(function(v) {
                                return { status: 'fulfilled', value: v };
                            }).catch(function(e) {
                                console.error("[ZenLocalService] symbol=" + arySymbol[idx].Symbol + " 请求失败:", e);
                                return { status: 'rejected', reason: e };
                            });
                        })(promises.length, p);
                    }
                }
            }

            if (promises.length === 0) {
                c.Callback({ ID: d.ID, Type: d.Type, AryData: [], ExtendData: d.ExtendData });
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

                        // 如果实时数据获取失败，构建空数据项
                        if (!realtime || !realtime.Data || realtime.Data.length === 0) {
                            stockItem = {
                                Symbol: sym, Name: "", YClose: 0, Close: 0,
                                High: 0, Low: 0, Open: 0, Vol: 0,
                                Increase: 0, UpDown: 0, Amplitude: 0,
                                Data: [], Minute: null, KLine: null
                            };
                        } else {
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
                        }
                    } else {
                        // 非 Type=1/2：检查 settled 结果
                        if (r.status === 'rejected' || !r.value) {
                            // 单个请求失败，构建空数据项
                            stockItem = { Symbol: sym, Name: "", Data: [], Code: 0 };
                            if (type === 100 || type === 101) stockItem.FlowCapital = false;
                            if (type === 3) stockItem.YClose = 0;
                        } else {
                            stockItem = buildStockItem(r.value, type);
                        }
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
                // 整体失败时返回空数据（而非 Error），确保 HQChart 关闭 splash
                console.error("[ZenLocalService] Request 整体失败:", e);
                var emptyAryData = buildEmptyAryData(arySymbol, type);
                if (c && c.Callback) c.Callback({
                    ID: d.ID, Type: d.Type,
                    AryData: emptyAryData,
                    ExtendData: d.ExtendData
                });
            });
        }
    };

    Object.defineProperty(window, 'ZenWSClient', {
        value: ZenWS,
        writable: false,
        configurable: false
    });
})();
