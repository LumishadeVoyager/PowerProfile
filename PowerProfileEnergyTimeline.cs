using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Windows.Forms;

public sealed class ProfileEnergyPeriod {
    public string Label {get;set;}
    public double? Cost {get;set;}
    public double? UsageHours {get;set;}
    public double? HighHours {get;set;}
    public double HighCoverageHours {get;set;}
    public double? GameHours {get;set;}
    public double GameCoverageHours {get;set;}
}

// Costs and hours have separate axes; unknown periods remain gaps.
public sealed class ProfileEnergyTimeline : Control {
    public List<ProfileEnergyPeriod> Periods=new List<ProfileEnergyPeriod>();
    readonly ToolTip tip=new ToolTip();int lastIndex=-1;
    static readonly Color[] colors={Color.FromArgb(39,106,159),Color.FromArgb(32,139,111),Color.FromArgb(212,130,43),Color.FromArgb(130,83,176)};
    public ProfileEnergyTimeline(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);BackColor=Color.White;}
    RectangleF Plot {get{return new RectangleF(44,40,Math.Max(1,Width-88),Math.Max(1,Height-70));}}
    static double? Value(ProfileEnergyPeriod p,int series){return series==0?p.Cost:series==1?p.UsageHours:series==2?p.HighHours:p.GameHours;}
    protected override void OnPaint(PaintEventArgs e){
        base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;var area=Plot;
        double maxCost=0.1,maxHours=1;bool any=false;
        foreach(var p in Periods){if(p.Cost.HasValue){maxCost=Math.Max(maxCost,p.Cost.Value);any=true;}for(int s=1;s<4;s++){var value=Value(p,s);if(value.HasValue){maxHours=Math.Max(maxHours,value.Value);any=true;}}}
        maxCost=Math.Ceiling(maxCost*10)/10;maxHours=Math.Ceiling(maxHours);
        string[] names={"电费 · 左轴 ¥","使用 · 右轴 h","高功耗 · 右轴 h","游戏 · 右轴 h"};float legendX=8;
        for(int s=0;s<4;s++)using(var pen=new Pen(colors[s],2))using(var brush=new SolidBrush(colors[s])){g.DrawLine(pen,legendX,9,legendX+12,9);g.DrawString(names[s],Font,brush,legendX+17,1);legendX+=g.MeasureString(names[s],Font).Width+31;}
        using(var grid=new Pen(Color.FromArgb(233,239,243)))using(var text=new SolidBrush(Color.FromArgb(111,122,132))){
            g.DrawString("¥",Font,text,4,23);g.DrawString("h",Font,text,Width-24,23);
            for(int i=0;i<=2;i++){float y=area.Bottom-area.Height*i/2;g.DrawLine(grid,area.Left,y,area.Right,y);g.DrawString((maxCost*i/2).ToString("0.0"),Font,text,2,y-7);g.DrawString((maxHours*i/2).ToString("0.#"),Font,text,area.Right+7,y-7);}
            for(int n=0;n<Math.Min(4,Periods.Count);n++){int index=(int)Math.Round(n*(Periods.Count-1)/Math.Max(1.0,Math.Min(4,Periods.Count)-1));float x=area.Left+area.Width*index/Math.Max(1,Periods.Count-1);string label=Periods[index].Label;var size=g.MeasureString(label,Font);g.DrawString(label,Font,text,x-size.Width/2,area.Bottom+9);}
            if(!any){const string empty="所选时段暂无记录 · 缺失数据留空";var size=g.MeasureString(empty,Font);g.DrawString(empty,Font,text,area.Left+(area.Width-size.Width)/2,area.Top+area.Height/2-7);}
        }
        for(int s=0;s<4;s++)using(var pen=new Pen(colors[s],2))using(var dot=new SolidBrush(colors[s])){
            PointF? previous=null;
            for(int i=0;i<Periods.Count;i++){double? value=Value(Periods[i],s);if(!value.HasValue){previous=null;continue;}
                var current=new PointF(area.Left+area.Width*i/Math.Max(1,Periods.Count-1),area.Bottom-(float)(value.Value/(s==0?maxCost:maxHours))*area.Height);
                if(previous.HasValue)g.DrawLine(pen,previous.Value,current);g.FillEllipse(dot,current.X-2,current.Y-2,4,4);previous=current;
            }
        }
    }
    static string Amount(double? value,string format,string unit){return value.HasValue?value.Value.ToString(format,CultureInfo.CurrentCulture)+unit:"未采集";}
    protected override void OnMouseMove(MouseEventArgs e){
        base.OnMouseMove(e);var area=Plot;int index=area.Contains(e.Location) && Periods.Count>0 ? (int)Math.Round((e.X-area.Left)/area.Width*(Periods.Count-1)) : -1;
        if(index==lastIndex)return;lastIndex=index;if(index<0){tip.SetToolTip(this,"");return;}var p=Periods[index];
        tip.SetToolTip(this,p.Label+"\n电费："+Amount(p.Cost,"0.00"," 元")+"\n使用："+Amount(p.UsageHours,"0.00"," 小时")+"\n高功耗："+Amount(p.HighHours,"0.00"," 小时")+"\n游戏："+Amount(p.GameHours,"0.00"," 小时")+"\n高功耗覆盖："+p.HighCoverageHours.ToString("0.00")+" 小时；游戏识别覆盖："+p.GameCoverageHours.ToString("0.00")+" 小时；未统计部分未知");
    }
    protected override void OnMouseLeave(EventArgs e){base.OnMouseLeave(e);lastIndex=-1;tip.SetToolTip(this,"");}
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
}
