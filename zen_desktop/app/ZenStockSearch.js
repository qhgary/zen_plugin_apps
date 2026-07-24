(function() {
    'use strict';

    var CONFIG = {
        DEBOUNCE_MS: 300,
        MAX_RESULTS: 10,
        MIN_QUERY_LENGTH: 2,
        CACHE_SIZE: 50,
        CACHE_TTL: 300000
    };

    var searchCache = {
        data: {},
        order: [],
        maxSize: CONFIG.CACHE_SIZE,
        ttl: CONFIG.CACHE_TTL,

        get: function(key) {
            var entry = this.data[key];
            if (!entry) return null;
            if (Date.now() - entry.time > this.ttl) {
                this.remove(key);
                return null;
            }
            return entry.value;
        },

        set: function(key, value) {
            if (this.order.length >= this.maxSize) {
                var oldest = this.order.shift();
                delete this.data[oldest];
            }
            this.data[key] = {
                value: value,
                time: Date.now()
            };
            this.order.push(key);
        },

        remove: function(key) {
            delete this.data[key];
            var index = this.order.indexOf(key);
            if (index > -1) {
                this.order.splice(index, 1);
            }
        }
    };

    function debounce(func, wait) {
        var timeout;
        return function() {
            var context = this;
            var args = arguments;
            clearTimeout(timeout);
            timeout = setTimeout(function() {
                func.apply(context, args);
            }, wait);
        };
    }

    function StockSearch(inputElement, options) {
        this.input = inputElement;
        this.options = options || {};
        this.dropdown = null;
        this.selectedIndex = -1;
        this.results = [];
        this.isVisible = false;
        this.onSelect = this.options.onSelect || function() {};

        this.init();
    }

    StockSearch.prototype.init = function() {
        this.createDropdown();
        this.bindEvents();
    };

    StockSearch.prototype.createDropdown = function() {
        this.dropdown = document.createElement('div');
        this.dropdown.id = 'SearchDropdown';
        this.dropdown.className = 'search-dropdown';
        this.dropdown.style.display = 'none';

        var parent = this.input.parentElement;
        if (parent) {
            parent.style.position = 'relative';
            parent.insertBefore(this.dropdown, this.input);
        }
    };

    StockSearch.prototype.bindEvents = function() {
        var self = this;

        var debouncedSearch = debounce(function() {
            self.handleInput();
        }, CONFIG.DEBOUNCE_MS);

        this.input.addEventListener('input', debouncedSearch);

        this.input.addEventListener('keydown', function(e) {
            if (self.isVisible) {
                switch (e.key) {
                    case 'ArrowDown':
                        e.preventDefault();
                        self.navigate(1);
                        return;
                    case 'ArrowUp':
                        e.preventDefault();
                        self.navigate(-1);
                        return;
                    case 'Enter':
                        e.preventDefault();
                        if (self.selectedIndex >= 0) {
                            self.selectItem(self.selectedIndex);
                            return;
                        }
                        break;
                    case 'Escape':
                        e.preventDefault();
                        self.hide();
                        return;
                }
            }
        });

        this.input.addEventListener('focus', function() {
            if (self.results.length > 0) {
                self.show();
            }
        });

        document.addEventListener('click', function(e) {
            if (!self.input.contains(e.target) && !self.dropdown.contains(e.target)) {
                self.hide();
            }
        });
    };

    StockSearch.prototype.handleInput = function() {
        var query = this.input.value.trim();

        if (query.length < CONFIG.MIN_QUERY_LENGTH) {
            this.hide();
            this.results = [];
            return;
        }

        var cached = searchCache.get(query);
        if (cached) {
            this.results = cached;
            this.render();
            return;
        }

        this.search(query);
    };

    StockSearch.prototype.search = function(query) {
        var self = this;

        var apiBase = window.location.origin || (window.location.protocol + '//' + window.location.host);
        var url = apiBase + '/api/search?q=' + encodeURIComponent(query);

        var headers = (typeof window._zenApiHeaders === 'function') ? window._zenApiHeaders() : {};

        fetch(url, { headers: headers })
            .then(function(response) {
                if (!response.ok) {
                    throw new Error('HTTP ' + response.status);
                }
                return response.json();
            })
            .then(function(data) {
                if (data && data.success && Array.isArray(data.results)) {
                    var filtered = data.results.filter(function(item) {
                        return item.market !== 'us';
                    });
                    self.results = filtered.slice(0, CONFIG.MAX_RESULTS);
                    searchCache.set(query, self.results);
                    self.render();
                } else {
                    self.results = [];
                    self.hide();
                }
            })
            .catch(function() {
                self.results = [];
                self.hide();
            });
    };

    StockSearch.prototype.render = function() {
        if (this.results.length === 0) {
            this.dropdown.innerHTML = '<div class="search-empty">未找到匹配股票</div>';
            this.show();
            return;
        }

        this.dropdown.innerHTML = '';
        this.selectedIndex = -1;

        for (var i = 0; i < this.results.length; i++) {
            var item = this.results[i];
            var div = document.createElement('div');
            div.className = 'search-item';
            div.setAttribute('data-index', i);
            div.setAttribute('data-market', item.market);
            div.setAttribute('data-code', item.code);

            var codeSpan = document.createElement('span');
            codeSpan.className = 'search-code';
            codeSpan.textContent = item.code;

            var nameSpan = document.createElement('span');
            nameSpan.className = 'search-name';
            nameSpan.textContent = item.name;

            var tagSpan = document.createElement('span');
            tagSpan.className = 'search-tag tag-' + (item.market === 'hk' ? 'hk' : 'a');
            tagSpan.textContent = item.type;

            div.appendChild(codeSpan);
            div.appendChild(nameSpan);
            div.appendChild(tagSpan);
            this.dropdown.appendChild(div);
        }

        this.bindItemEvents();
        this.show();
    };

    StockSearch.prototype.bindItemEvents = function() {
        var self = this;
        var items = this.dropdown.querySelectorAll('.search-item');

        for (var i = 0; i < items.length; i++) {
            (function(item) {
                item.addEventListener('click', function(e) {
                    e.preventDefault();
                    e.stopPropagation();
                    var index = parseInt(this.getAttribute('data-index'));
                    self.selectItem(index);
                });

                item.addEventListener('mouseenter', function() {
                    self.highlightItem(parseInt(this.getAttribute('data-index')));
                });
            })(items[i]);
        }
    };

    StockSearch.prototype.navigate = function(direction) {
        if (this.results.length === 0) return;

        var newIndex = this.selectedIndex + direction;
        if (newIndex < 0) newIndex = this.results.length - 1;
        if (newIndex >= this.results.length) newIndex = 0;

        this.highlightItem(newIndex);
    };

    StockSearch.prototype.highlightItem = function(index) {
        if (index < 0 || index >= this.results.length) return;

        var items = this.dropdown.querySelectorAll('.search-item');
        for (var i = 0; i < items.length; i++) {
            items[i].classList.remove('highlighted');
        }

        this.selectedIndex = index;
        items[index].classList.add('highlighted');

        items[index].scrollIntoView({ block: 'nearest' });
    };

    StockSearch.prototype.selectItem = function(index) {
        if (index < 0 || index >= this.results.length) return;

        var item = this.results[index];
        var fullCode = item.code;
        if (item.market === 'hk') {
            fullCode = item.code + '.hk';
        } else if (item.market === 'sh') {
            fullCode = item.code + '.sh';
        } else if (item.market === 'sz') {
            fullCode = item.code + '.sz';
        } else if (item.market === 'bj') {
            fullCode = item.code + '.bj';
        }

        this.input.value = fullCode;
        this.hide();
        this.results = [];

        this.onSelect(item);

        if (this.input.form) {
            this.input.form.dispatchEvent(new Event('submit', { cancelable: true }));
        }

        var addBtn = document.getElementById('AddWatch');
        if (addBtn && typeof addBtn.onclick === 'function') {
            addBtn.onclick();
        }
    };

    StockSearch.prototype.show = function() {
        this.dropdown.style.display = 'block';
        this.isVisible = true;
    };

    StockSearch.prototype.hide = function() {
        this.dropdown.style.display = 'none';
        this.isVisible = false;
        this.selectedIndex = -1;
    };

    window.ZenStockSearch = StockSearch;
})();
