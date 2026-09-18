// ================== 自定义实心圆点绘图类 ==================
// 解决原生 ChartDrawPictureText 和 ChartDrawPictureIconFont
// 在图表垂直缩放时可能产生 textBaseline 对齐偏移以及不同字体渲染差异问题
window.ChartDrawPictureSolidZenDot = function() {
    if (typeof IChartDrawPicture !== 'undefined') {
        this.newMethod = IChartDrawPicture;
        this.newMethod();
        delete this.newMethod;
    }

    this.ClassName = 'ChartDrawPictureSolidZenDot';
    this.PointCount = 1;
    this.FontOption = { Size: 5 }; // Size 表示圆的视觉实心直径

    this.SetOption = function(option) {
        if (!option) return;
        if (option.LineColor) this.LineColor = option.LineColor;
        if (option.Color) this.Color = option.Color;
        if (option.FontOption && typeof option.FontOption.Size === 'number') this.FontOption.Size = option.FontOption.Size;
    };

    this.Draw = function() {
        if (this.IsFrameMinSize()) return;
        if (!this.IsShow) return;

        var drawPoint = this.CalculateDrawPoint({IsCheckX:true, IsCheckY:true});
        if (!drawPoint || drawPoint.length != 1) return;

        var pixel = typeof GetDevicePixelRatio === 'function' ? GetDevicePixelRatio() : 1;
        var r = (this.FontOption.Size / 2.0) * Math.max(1, Math.min(pixel, 2));

        this.ClipFrame();

        this.Canvas.fillStyle = this.LineColor || this.Color || 'white';
        this.Canvas.beginPath();
        // 取数据绝对坐标作为圆心画实心圆，彻底解决拉伸漂移
        this.Canvas.arc(drawPoint[0].X, drawPoint[0].Y, r, 0, 2*Math.PI);
        this.Canvas.fill();
        
        this.Canvas.restore();

        this.TextRect = {
            Left: drawPoint[0].X - r,
            Top: drawPoint[0].Y - r,
            Width: r * 2,
            Height: r * 2
        };
    };
    
    this.IsPointIn = function(x, y) {
        return -1;
    };
};

// 自动向 umychart 内部工厂注册
if (typeof IChartDrawPicture !== 'undefined' && typeof IChartDrawPicture.RegisterDrawPicture === 'function') {
    if (!IChartDrawPicture.GetDrawPictureByClassName('ChartDrawPictureSolidZenDot')) {
        IChartDrawPicture.RegisterDrawPicture({
            Name: '缠论自适应实心圆点',
            ClassName: 'ChartDrawPictureSolidZenDot',
            Create: function() { return new ChartDrawPictureSolidZenDot(); }
        });
    }
}
