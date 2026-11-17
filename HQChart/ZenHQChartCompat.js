(function (global) {
    function getSeparatorName() {
        return global.JSPopMenu ? global.JSPopMenu.SEPARATOR_LINE_NAME : null;
    }

    function shouldRemoveMenuItem(item) {
        if (!item) return false;

        var menuId = item.Data && item.Data.ID;
        if (global.JSCHART_MENU_ID) {
            if (menuId === global.JSCHART_MENU_ID.CMD_SHOW_MAXMIN_ID) return true;
            if (menuId === global.JSCHART_MENU_ID.CMD_DELETE_INDEX_ID) return true;
        }

        return item.Name === "显示最大最小值" || item.Name === "删除主图指标";
    }

    function cleanupSeparators(menu) {
        if (!Array.isArray(menu)) return [];

        var separatorName = getSeparatorName();
        var result = [];
        for (var i = 0; i < menu.length; ++i) {
            var item = menu[i];
            if (!item) continue;

            var isSeparator = separatorName && item.Name === separatorName;
            if (isSeparator) {
                if (result.length <= 0) continue;
                var last = result[result.length - 1];
                if (last && last.Name === separatorName) continue;
            }

            result.push(item);
        }

        while (result.length > 0 && separatorName && result[result.length - 1].Name === separatorName) {
            result.pop();
        }

        return result;
    }

    function filterMenuTree(menu) {
        if (!Array.isArray(menu)) return [];

        var result = [];
        for (var i = 0; i < menu.length; ++i) {
            var item = menu[i];
            if (!item) continue;
            if (shouldRemoveMenuItem(item)) continue;

            if (Array.isArray(item.SubMenu)) {
                item.SubMenu = cleanupSeparators(filterMenuTree(item.SubMenu));
                if (item.SubMenu.length <= 0) continue;
            }

            result.push(item);
        }

        return cleanupSeparators(result);
    }

    function onCreateRightMenu(event, data) {
        if (!data || !data.MenuData || !Array.isArray(data.MenuData.Menu)) return;
        data.MenuData.Menu = filterMenuTree(data.MenuData.Menu);
    }

    function installRightMenuFilter(option) {
        if (!option || !global.JSCHART_EVENT_ID) return option;
        if (!Array.isArray(option.EventCallback)) option.EventCallback = [];

        for (var i = 0; i < option.EventCallback.length; ++i) {
            if (option.EventCallback[i] && option.EventCallback[i].__zenCompatRightMenu) return option;
        }

        option.EventCallback.push({
            event: global.JSCHART_EVENT_ID.ON_CREATE_RIGHT_MENU,
            callback: onCreateRightMenu,
            __zenCompatRightMenu: true
        });

        return option;
    }

    function patchStyle(style) {
        if (style) style.DisableLogo = true;
        return style;
    }

    function getScrollPosition() {
        if (typeof global.GetScrollPosition === "function") return global.GetScrollPosition();
        return { Top: 0, Left: 0 };
    }

    function clampDialogToViewport(div) {
        if (!div) return;

        var margin = 4;
        var scrollPos = getScrollPosition();
        var vw = window.innerWidth;
        var vh = window.innerHeight;
        var w = div.offsetWidth;
        var h = div.offsetHeight;
        var left = parseFloat(div.style.left) || 0;
        var top = parseFloat(div.style.top) || 0;
        var viewLeft = left - scrollPos.Left;
        var viewTop = top - scrollPos.Top;

        if (viewLeft + w > vw - margin) viewLeft = Math.max(margin, vw - w - margin);
        if (viewTop + h > vh - margin) viewTop = Math.max(margin, vh - h - margin);
        if (viewLeft < margin) viewLeft = margin;
        if (viewTop < margin) viewTop = margin;

        div.style.left = (viewLeft + scrollPos.Left) + "px";
        div.style.top = (viewTop + scrollPos.Top) + "px";
    }

    function bindDialogDismissOnOutsideClick(proto) {
        if (!proto || proto.__zenDismissOnOutsideClick) return;

        var origShow = proto.Show;
        proto.Show = function () {
            var self = this;
            origShow.apply(this, arguments);

            if (self.DivDialog) clampDialogToViewport(self.DivDialog);

            if (!self.__zenOutsideCloseHandler) {
                self.__zenOutsideCloseHandler = function (e) {
                    if (!self.DivDialog || self.DivDialog.style.visibility !== "visible") return;
                    if (self.DivDialog.contains(e.target)) return;
                    self.Close(e);
                };
            }

            document.addEventListener("mousedown", self.__zenOutsideCloseHandler, true);
            document.addEventListener("touchstart", self.__zenOutsideCloseHandler, true);
        };

        var origClose = proto.Close;
        proto.Close = function () {
            if (this.__zenOutsideCloseHandler) {
                document.removeEventListener("mousedown", this.__zenOutsideCloseHandler, true);
                document.removeEventListener("touchstart", this.__zenOutsideCloseHandler, true);
            }
            origClose.apply(this, arguments);
        };

        proto.__zenDismissOnOutsideClick = true;
    }

    function patchSearchIndexDialog() {
        if (!global.JSDialogSearchIndex || !global.JSDialogSearchIndex.prototype) return;
        var proto = global.JSDialogSearchIndex.prototype;
        if (proto.__zenSearchIndexPatched) return;

        bindDialogDismissOnOutsideClick(proto);

        var origOnClickIndex = proto.OnClickIndex;
        proto.OnClickIndex = function (e, cellItem) {
            origOnClickIndex.call(this, e, cellItem);
            if (this.OpData) this.Close(e);
        };

        proto.__zenSearchIndexPatched = true;
    }

    function patchModifyIndexParamDialog() {
        if (!global.JSDialogModifyIndexParam || !global.JSDialogModifyIndexParam.prototype) return;
        var proto = global.JSDialogModifyIndexParam.prototype;
        if (proto.__zenModifyIndexParamPatched) return;

        bindDialogDismissOnOutsideClick(proto);
        proto.__zenModifyIndexParamPatched = true;
    }

    function installDialogPatches() {
        patchSearchIndexDialog();
        patchModifyIndexParamDialog();
    }

    installDialogPatches();

    global.ZenHQChartCompat = {
        installRightMenuFilter: installRightMenuFilter,
        patchStyle: patchStyle,
        installDialogPatches: installDialogPatches
    };
})(window);
