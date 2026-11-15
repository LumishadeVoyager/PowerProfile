// Compiled with the energy adapter so chart values share its nullable data model.
public sealed class ProfileEnergySelectionEventArgs : System.EventArgs {
    public int Index;public string Key;
    public ProfileEnergySelectionEventArgs(int index,string key){Index=index;Key=key;}
}
public sealed class ProfileInteractiveTimeline : System.Windows.Forms.Control {
    public System.Collections.Generic.List<ProfileEnergyPeriod> Periods=new System.Collections.Generic.List<ProfileEnergyPeriod>();
    public bool[] SeriesVisible={true,true,true,true};public bool DarkMode;
    public int ViewStart {get;private set;}public int ViewCount {get;private set;}
    public int SelectedIndex {get;private set;}
    public event System.EventHandler<ProfileEnergySelectionEventArgs> PeriodSelected;
    readonly System.Windows.Forms.ToolTip tip=new System.Windows.Forms.ToolTip();int drag=-1,hover=-1;
    public ProfileInteractiveTimeline(){DoubleBuffered=true;TabStop=true;Height=290;AccessibleName="费用与使用时长交互图；左右键选择，加减键缩放，Home 恢复";SelectedIndex=-1;}
    int Count {get{return ViewCount<=0?Periods.Count:System.Math.Min(ViewCount,Periods.Count-ViewStart);}}
    System.Drawing.RectangleF Plot {get{return new System.Drawing.RectangleF(49,45,System.Math.Max(1,Width-100),System.Math.Max(1,Height-82));}}
    System.Drawing.Color GridColor {get{return DarkMode?System.Drawing.Color.FromArgb(65,75,89):System.Drawing.Color.FromArgb(222,231,241);}}
    System.Drawing.Color Color(int n){return n==0?(DarkMode?System.Drawing.Color.FromArgb(117,185,255):System.Drawing.Color.FromArgb(32,104,184)):n==1?(DarkMode?System.Drawing.Color.FromArgb(86,209,173):System.Drawing.Color.FromArgb(32,139,111)):n==2?(DarkMode?System.Drawing.Color.FromArgb(250,185,88):System.Drawing.Color.FromArgb(204,125,32)):(DarkMode?System.Drawing.Color.FromArgb(195,157,252):System.Drawing.Color.FromArgb(130,83,176));}
    static double? Value(ProfileEnergyPeriod p,int s){return s==0?p.Cost:s==1?p.UsageHours:s==2?p.HighHours:p.GameHours;}
    public void ResetView(){ViewStart=0;ViewCount=0;Invalidate();}
    public void SetView(int start,int count){ViewStart=System.Math.Max(0,System.Math.Min(start,System.Math.Max(0,Periods.Count-1)));ViewCount=System.Math.Max(1,System.Math.Min(count,Periods.Count-ViewStart));Invalidate();}
    public void SelectIndex(int index){if(index<0||index>=Periods.Count)return;SelectedIndex=index;if(PeriodSelected!=null)PeriodSelected(this,new ProfileEnergySelectionEventArgs(index,Periods[index].Key));Invalidate();}
    int IndexAt(int x){return Count<1?-1:ViewStart+(int)System.Math.Round(System.Math.Max(0,System.Math.Min(1,(x-Plot.Left)/Plot.Width))*(Count-1));}
    protected override void OnPaint(System.Windows.Forms.PaintEventArgs e){base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;g.Clear(BackColor);var area=Plot;double cost=0.1,hours=1;bool any=false;
        if(ViewStart>=Periods.Count){ViewStart=0;ViewCount=0;}
        for(int i=ViewStart;i<ViewStart+Count;i++)for(int s=0;s<4;s++){var v=Value(Periods[i],s);if(!SeriesVisible[s]||!v.HasValue)continue;any=true;if(s==0)cost=System.Math.Max(cost,v.Value);else hours=System.Math.Max(hours,v.Value);}
        cost=System.Math.Ceiling(cost*10)/10;hours=System.Math.Ceiling(hours);
        using(var grid=new System.Drawing.Pen(GridColor))using(var text=new System.Drawing.SolidBrush(ForeColor)){
            g.DrawString("费用 ¥",Font,text,2,16);g.DrawString("时长 h",Font,text,Width-54,16);
            for(int n=0;n<=4;n++){float y=area.Bottom-area.Height*n/4;g.DrawLine(grid,area.Left,y,area.Right,y);g.DrawString((cost*n/4).ToString("0.##"),Font,text,1,y-7);g.DrawString((hours*n/4).ToString("0.#"),Font,text,area.Right+5,y-7);}
            for(int n=0;n<System.Math.Min(5,Count);n++){int relative=(int)System.Math.Round(n*(Count-1)/System.Math.Max(1.0,System.Math.Min(5,Count)-1));string label=Periods[ViewStart+relative].Label;float x=area.Left+area.Width*relative/System.Math.Max(1,Count-1);var size=g.MeasureString(label,Font);g.DrawString(label,Font,text,System.Math.Max(2,System.Math.Min(Width-size.Width-2,x-size.Width/2)),area.Bottom+12);}
            if(!any)g.DrawString("所选范围没有有效数据；缺失保留为空",Font,text,area.Left+10,area.Top+area.Height/2);
        }
        for(int s=0;s<4;s++){if(!SeriesVisible[s])continue;using(var pen=new System.Drawing.Pen(Color(s),2.4f))using(var brush=new System.Drawing.SolidBrush(Color(s))){if(s==2)pen.DashStyle=System.Drawing.Drawing2D.DashStyle.Dash;if(s==3)pen.DashStyle=System.Drawing.Drawing2D.DashStyle.Dot;System.Drawing.PointF? previous=null;for(int r=0;r<Count;r++){var p=Periods[ViewStart+r];var v=Value(p,s);if(!v.HasValue){previous=null;continue;}var point=new System.Drawing.PointF(area.Left+area.Width*r/System.Math.Max(1,Count-1),area.Bottom-(float)(v.Value/(s==0?cost:hours))*area.Height);if(previous.HasValue)g.DrawLine(pen,previous.Value,point);g.FillEllipse(brush,point.X-3,point.Y-3,6,6);previous=point;}}}
        if(SelectedIndex>=ViewStart&&SelectedIndex<ViewStart+Count)using(var pen=new System.Drawing.Pen(ForeColor,1)){pen.DashStyle=System.Drawing.Drawing2D.DashStyle.Dot;float x=area.Left+area.Width*(SelectedIndex-ViewStart)/System.Math.Max(1,Count-1);g.DrawLine(pen,x,area.Top,x,area.Bottom);}
        if(drag>=0&&hover>=0)using(var brush=new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(45,Color(0)))){float a=area.Left+area.Width*(drag-ViewStart)/System.Math.Max(1,Count-1),b=area.Left+area.Width*(hover-ViewStart)/System.Math.Max(1,Count-1);g.FillRectangle(brush,System.Math.Min(a,b),area.Top,System.Math.Abs(a-b),area.Height);}
    }
    string TextAt(int index){if(index<0||index>=Periods.Count)return "";var p=Periods[index];return p.Label+"\n费用："+(p.Cost.HasValue?p.Cost.Value.ToString("0.00")+" 元":"未采集")+"\n电脑使用："+Hours(p.UsageHours)+"\n高功耗（含估）："+Hours(p.HighHours)+"\n游戏："+Hours(p.GameHours)+"\n游戏档推算："+Hours(p.ModeGameHours)+"，不等于实测 ≥150 W\n高功耗实测覆盖："+p.HighCoverageHours.ToString("0.0")+" 小时";}
    static string Hours(double? v){return v.HasValue?v.Value.ToString("0.00")+" 小时":"未统计";}
    protected override void OnMouseMove(System.Windows.Forms.MouseEventArgs e){base.OnMouseMove(e);int i=Plot.Contains(e.Location)?IndexAt(e.X):-1;if(i!=hover){hover=i;tip.SetToolTip(this,TextAt(i));if(drag>=0)Invalidate();}}
    protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e){base.OnMouseDown(e);if(e.Button==System.Windows.Forms.MouseButtons.Left&&Plot.Contains(e.Location)){Focus();drag=IndexAt(e.X);Capture=true;}}
    protected override void OnMouseUp(System.Windows.Forms.MouseEventArgs e){base.OnMouseUp(e);if(drag<0)return;int end=IndexAt(e.X),start=drag;drag=-1;Capture=false;if(end>=0){if(System.Math.Abs(end-start)>1)SetView(System.Math.Min(start,end),System.Math.Abs(end-start)+1);else SelectIndex(end);}Invalidate();}
    protected override void OnMouseWheel(System.Windows.Forms.MouseEventArgs e){base.OnMouseWheel(e);if(Periods.Count<2)return;int count=System.Math.Max(2,System.Math.Min(Periods.Count,Count+(e.Delta>0?-System.Math.Max(1,Count/4):System.Math.Max(1,Count/3))));int center=IndexAt(e.X);SetView(System.Math.Max(0,center-count/2),count);}
    protected override bool IsInputKey(System.Windows.Forms.Keys keyData){return keyData==System.Windows.Forms.Keys.Left||keyData==System.Windows.Forms.Keys.Right||keyData==System.Windows.Forms.Keys.Home||keyData==System.Windows.Forms.Keys.Add||keyData==System.Windows.Forms.Keys.Subtract||keyData==System.Windows.Forms.Keys.Oemplus||keyData==System.Windows.Forms.Keys.OemMinus||base.IsInputKey(keyData);}
    protected override void OnKeyDown(System.Windows.Forms.KeyEventArgs e){base.OnKeyDown(e);if(e.KeyCode==System.Windows.Forms.Keys.Home)ResetView();if(e.KeyCode==System.Windows.Forms.Keys.Left)SelectIndex(System.Math.Max(0,SelectedIndex-1));if(e.KeyCode==System.Windows.Forms.Keys.Right)SelectIndex(System.Math.Min(Periods.Count-1,SelectedIndex+1));if(e.KeyCode==System.Windows.Forms.Keys.Add||e.KeyCode==System.Windows.Forms.Keys.Oemplus)SetView(ViewStart,System.Math.Max(2,Count/2));if(e.KeyCode==System.Windows.Forms.Keys.Subtract||e.KeyCode==System.Windows.Forms.Keys.OemMinus)SetView(ViewStart,System.Math.Min(Periods.Count,Count*2));}
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
}
