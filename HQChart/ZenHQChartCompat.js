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

    global.ZenHQChartCompat = {
        installRightMenuFilter: installRightMenuFilter,
        patchStyle: patchStyle
    };
})(window);
