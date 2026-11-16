using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Linq;
using System.Windows.Forms;
using Microsoft.Win32;

public sealed class ProfileWorkspaceCommand : EventArgs {
    public string Action,Id;
    public ProfileWorkspaceCommand(string action,string id){Action=action;Id=id;}
}
public sealed class ProfileDeviceView {
    public string Id,Name,Model,Room,Status,Details,Next;
    public bool Favorite,CanControl,ComputerPower;
}
public sealed class ProfileScheduleSlot {
    public string Id,Device,Name,Status;
    public DateTime Start,End;
    public bool On,Paused,Conflict,Instant;
}
public sealed class ProfileLedgerView {
    public string Key,Date,Energy,Cost,Usage,High,Game,Source,Explanation,Names;
    public bool Estimated,Missing;
    public DateTime PeriodStart,PeriodEnd;
    public double? KWhNumber,CostNumber,UsageSeconds,HighSeconds,GameSeconds;
}
public static class ProfileTheme {
    public static bool Dark;
    public static Color Background {get{return SystemInformation.HighContrast?SystemColors.Window:ProfileSkin.Liquid?(Dark?Color.FromArgb(21,31,49):Color.FromArgb(226,236,248)):Dark?Color.FromArgb(24,27,33):Color.FromArgb(245,247,250);}}
    public static Color Surface {get{return SystemInformation.HighContrast?SystemColors.Window:ProfileSkin.Liquid?(Dark?Color.FromArgb(34,49,70):Color.FromArgb(240,246,253)):Dark?Color.FromArgb(34,39,47):Color.White;}}
    public static Color Text {get{return SystemInformation.HighContrast?SystemColors.WindowText:Dark?Color.FromArgb(233,237,242):Color.FromArgb(33,44,60);}}
    public static Color Muted {get{return SystemInformation.HighContrast?SystemColors.GrayText:Dark?Color.FromArgb(166,178,194):Color.FromArgb(96,112,131);}}
    public static Color Border {get{return SystemInformation.HighContrast?SystemColors.WindowFrame:Dark?Color.FromArgb(60,69,83):Color.FromArgb(221,228,237);}}
    public static Color Accent {get{return SystemInformation.HighContrast?SystemColors.HotTrack:Dark?Color.FromArgb(115,182,248):Color.FromArgb(32,104,184);}}
    public static Color Selection {get{return SystemInformation.HighContrast?SystemColors.Highlight:Dark?Color.FromArgb(42,65,87):Color.FromArgb(228,239,252);}}
    public static bool SystemDark(){try{return Convert.ToInt32(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize","AppsUseLightTheme",1))==0;}catch{return false;}}
    public static void Apply(Control root,bool dark){if(Dark!=dark){Dark=dark;ProfileSkin.Changed();}Style(root);root.Invalidate(true);}
    public static void ApplyWindow(Form form){Style(form);if(!(form is ProfileWorkspaceForm))ProfileGlass.Apply(form,ProfileSkin.SystemBlur&&ProfileSkin.Kind!="Standard",0);form.Invalidate(true);}
    public static void Style(Control root){Paint(root);}
    static void Paint(Control c){
        bool alert=c.ForeColor.R>140&&c.ForeColor.R>c.ForeColor.G*1.35&&c.ForeColor.B<c.ForeColor.R*.85;bool surface=c is ProfileSurface || c is TextBoxBase || c is ComboBox || c is NumericUpDown || c is DataGridView;
        c.BackColor=surface?Surface:(c is Form||c.Parent==null?Background:c.Parent.BackColor);c.ForeColor=alert?(Dark?Color.FromArgb(255,157,151):Color.FromArgb(182,48,43)):Text;
        if(ProfileSkin.Liquid&&(c is CheckBox||c is RadioButton||c is GroupBox))c.BackColor=Color.Transparent;
        if(c is Label && (ProfileSkin.Liquid || c.Parent is ProfileMetric && ((ProfileMetric)c.Parent).Featured))c.BackColor=Color.Transparent;
        if(c is Label && (c.Tag as string)=="muted")c.ForeColor=Muted;
        var b=c as Button;if(b!=null){b.FlatStyle=FlatStyle.Flat;b.FlatAppearance.BorderColor=Border;b.BackColor=Surface;b.ForeColor=Text;b.Padding=new Padding(8,3,8,3);}
        var g=c as DataGridView;if(g!=null){g.BackgroundColor=Surface;g.GridColor=Border;g.DefaultCellStyle.BackColor=Surface;g.DefaultCellStyle.ForeColor=Text;g.DefaultCellStyle.SelectionBackColor=Selection;g.DefaultCellStyle.SelectionForeColor=SystemInformation.HighContrast?SystemColors.HighlightText:Text;g.AlternatingRowsDefaultCellStyle.BackColor=Background;g.ColumnHeadersDefaultCellStyle.BackColor=Background;g.ColumnHeadersDefaultCellStyle.ForeColor=Muted;}
        var link=c as LinkLabel;if(link!=null)link.LinkColor=Accent;
        ProfileSkin.Native(c);foreach(Control child in c.Controls)Paint(child);
        if(c is ProfileSurface)c.Invalidate();
    }
}
public class ProfileSurface : Panel {
    public ProfileSurface(){DoubleBuffered=true;Font=new Font("Microsoft YaHei UI",9F);Padding=new Padding(14);Margin=new Padding(0,0,10,10);BackColor=ProfileTheme.Surface;}
    protected override void OnPaintBackground(PaintEventArgs e){if(ProfileSkin.Liquid){ProfileSkin.Canvas(this,e.Graphics);ProfileSkin.Glass(this,e.Graphics,new RectangleF(.5f,.5f,Width-1,Height-1),18,false);return;}e.Graphics.Clear(Parent==null?ProfileTheme.Background:Parent.BackColor);using(var path=ProfileMotion.Round(new RectangleF(0,0,Width-1,Height-1),12))using(var brush=new SolidBrush(BackColor)){e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;e.Graphics.FillPath(brush,path);}}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);if(ProfileSkin.Liquid)return;using(var path=ProfileMotion.Round(new RectangleF(.5f,.5f,Width-1,Height-1),12))using(var p=new Pen(ProfileTheme.Border))e.Graphics.DrawPath(p,path);}
}
public static class ProfileMotion {
    public static bool Enabled=true;
    [System.Runtime.InteropServices.DllImport("user32.dll",SetLastError=true)]static extern bool SystemParametersInfo(uint action,uint parameter,out int value,uint flags);
    public static bool Allowed {get{int animate;return Enabled&&!SystemInformation.HighContrast&&SystemParametersInfo(0x1042,0,out animate,0)&&animate!=0;}}
    public static GraphicsPath Round(RectangleF r,float radius){var p=new GraphicsPath();float d=Math.Min(radius*2,Math.Min(r.Width,r.Height));if(d<1){p.AddRectangle(r);return p;}p.AddArc(r.X,r.Y,d,d,180,90);p.AddArc(r.Right-d,r.Y,d,d,270,90);p.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);p.AddArc(r.X,r.Bottom-d,d,d,90,90);p.CloseFigure();return p;}
    public static Color Mix(Color a,Color b,float v){v=Math.Max(0,Math.Min(1,v));return Color.FromArgb((int)(a.R+(b.R-a.R)*v),(int)(a.G+(b.G-a.G)*v),(int)(a.B+(b.B-a.B)*v));}
}
public sealed class ProfileActionButton : Button {
    readonly Timer motion=new Timer{Interval=16};float hover,target;bool down;
    public bool Selected;
    public ProfileActionButton(){DoubleBuffered=true;FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);motion.Tick+=(s,e)=>{if(!ProfileMotion.Allowed||!Visible){hover=target;motion.Stop();}else{hover+=(target-hover)*.35f;if(Math.Abs(target-hover)<.02f){hover=target;motion.Stop();}}Invalidate();};}
    void MoveTo(float v){target=v;if(ProfileMotion.Allowed&&Visible)motion.Start();else{hover=v;motion.Stop();Invalidate();}}
    protected override void OnMouseEnter(EventArgs e){base.OnMouseEnter(e);MoveTo(1);}
    protected override void OnMouseLeave(EventArgs e){base.OnMouseLeave(e);down=false;MoveTo(0);}
    protected override void OnMouseDown(MouseEventArgs e){base.OnMouseDown(e);down=true;Invalidate();}
    protected override void OnMouseUp(MouseEventArgs e){base.OnMouseUp(e);down=false;Invalidate();}
    protected override void OnPaint(PaintEventArgs e){var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(Parent==null?ProfileTheme.Background:Parent.BackColor);var color=Selected?ProfileTheme.Selection:ProfileMotion.Mix(ProfileTheme.Surface,ProfileTheme.Selection,down?1:hover*.65f);if(ProfileSkin.Liquid){ProfileSkin.Canvas(this,g);ProfileSkin.Glass(this,g,new RectangleF(.5f,.5f,Width-1,Height-1),Math.Min(18,Height/2f),Selected||down||hover>.4f);}else using(var p=ProfileMotion.Round(new RectangleF(.5f,.5f,Width-1,Height-1),8))using(var brush=new SolidBrush(color))using(var pen=new Pen(Selected?ProfileTheme.Selection:ProfileTheme.Border)){g.FillPath(brush,p);if(!Selected)g.DrawPath(pen,p);}TextRenderer.DrawText(g,Text,Font,new Rectangle(6,3,Width-12,Height-6),Enabled?(Selected?ProfileTheme.Accent:ProfileTheme.Text):ProfileTheme.Muted,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);if(Focused&&ShowFocusCues)ControlPaint.DrawFocusRectangle(g,new Rectangle(4,4,Width-8,Height-8));}
    protected override void OnVisibleChanged(EventArgs e){base.OnVisibleChanged(e);if(!Visible)motion.Stop();}
    protected override void Dispose(bool disposing){if(disposing)motion.Dispose();base.Dispose(disposing);}
}
public sealed class ProfileDisclosure : Panel {
    public readonly Button Toggle=new ProfileActionButton();public readonly FlowLayoutPanel Body=new FlowLayoutPanel();bool expanded,laying;string title;
    public string Caption {get{return title;}set{title=value;Toggle.Text=(expanded?"−  ":"＋  ")+title;}}
    public bool Expanded {get{return expanded;}set{bool opening=value&&!expanded;expanded=value;Toggle.Text=(value?"−  ":"＋  ")+title;Toggle.AccessibleDescription=value?"已展开":"已折叠";Body.Visible=value;PerformLayout();if(Parent!=null)Parent.PerformLayout();if(opening&&IsHandleCreated&&Visible)BeginInvoke((Action)(()=>{if(!IsDisposed&&expanded&&Visible)RevealContents();}));}}
    public ProfileDisclosure(string title){this.title=title;DoubleBuffered=true;Margin=new Padding(0,2,0,8);Toggle.Height=32;Toggle.Text="＋  "+title;Toggle.AccessibleName=title;Toggle.Click+=(s,e)=>Expanded=!Expanded;Body.FlowDirection=FlowDirection.TopDown;Body.WrapContents=false;Body.AutoSize=true;Body.AutoSizeMode=AutoSizeMode.GrowAndShrink;Body.Margin=Padding.Empty;Controls.Add(Body);Controls.Add(Toggle);Body.SizeChanged+=(s,e)=>PerformLayout();Body.Visible=false;Height=36;}
    public void Add(params Control[] controls){foreach(var c in controls)Body.Controls.Add(c);PerformLayout();}
    void RevealContents(){ScrollableControl host=null;for(Control c=Parent;c!=null;c=c.Parent){var candidate=c as ScrollableControl;if(candidate!=null&&candidate.AutoScroll){host=candidate;break;}}if(host==null)return;host.PerformLayout();var bounds=host.RectangleToClient(RectangleToScreen(ClientRectangle));int y=-host.AutoScrollPosition.Y,space=host.ClientSize.Height;if(bounds.Height>space-12)y+=bounds.Top-6;else if(bounds.Bottom>space-6)y+=bounds.Bottom-space+6;else if(bounds.Top<0)y+=bounds.Top-6;host.AutoScrollPosition=new Point(-host.AutoScrollPosition.X,Math.Max(0,y));}
    protected override void OnLayout(LayoutEventArgs e){base.OnLayout(e);if(laying)return;laying=true;try{int width=Math.Max(50,ClientSize.Width);Toggle.SetBounds(0,0,width,Math.Max(32,Toggle.Font.Height+14));Body.Location=new Point(0,Toggle.Bottom+6);Body.MinimumSize=Size.Empty;Body.MaximumSize=new Size(width,0);Body.MinimumSize=new Size(width,0);foreach(Control c in Body.Controls){c.Dock=DockStyle.None;c.Width=width-4;if(c is Label)((Label)c).MaximumSize=new Size(width-4,0);}Body.PerformLayout();int h=expanded?Body.Bottom+4:Toggle.Bottom+2;if(Height!=h)Height=h;}finally{laying=false;}}
}
// Keep automatic tooltip registration stable while moving inside one hover target.
public sealed class ProfileHoverTip : IDisposable {
    readonly Control owner;readonly ToolTip tip=new ToolTip{InitialDelay=400,ReshowDelay=150,AutoPopDelay=12000,UseAnimation=false,UseFading=false};string current="";bool disposed;
    public ProfileHoverTip(Control owner){this.owner=owner;owner.MouseLeave+=Reset;owner.MouseDown+=Reset;owner.MouseWheel+=Reset;owner.SizeChanged+=Reset;owner.VisibleChanged+=Reset;owner.Disposed+=OwnerDisposed;}
    public bool Update(string text){if(disposed)return false;text=text??"";if(!owner.Visible)text="";if(String.Equals(current,text,StringComparison.Ordinal))return false;current=text;if(text.Length==0&&owner.IsHandleCreated)tip.Hide(owner);tip.SetToolTip(owner,text);return true;}
    void Reset(object sender,EventArgs e){Clear();}
    void OwnerDisposed(object sender,EventArgs e){Dispose();}
    public void Clear(){Update("");}
    public void Dispose(){if(disposed)return;disposed=true;owner.MouseLeave-=Reset;owner.MouseDown-=Reset;owner.MouseWheel-=Reset;owner.SizeChanged-=Reset;owner.VisibleChanged-=Reset;owner.Disposed-=OwnerDisposed;tip.Dispose();}
}
public sealed class ProfileNavigation : Panel {
    readonly Timer timer=new Timer{Interval=16};float left,width,startLeft,startWidth,targetLeft,targetWidth;readonly System.Diagnostics.Stopwatch watch=new System.Diagnostics.Stopwatch();
    public bool Animating {get{return timer.Enabled;}}
    public ProfileNavigation(){DoubleBuffered=true;timer.Tick+=(s,e)=>{float t=Math.Min(1,(float)watch.Elapsed.TotalMilliseconds/150);if(!Visible||!ProfileMotion.Allowed)t=1;float f=1-(float)Math.Pow(1-t,3);left=startLeft+(targetLeft-startLeft)*f;width=startWidth+(targetWidth-startWidth)*f;if(t>=1)timer.Stop();Invalidate();};}
    public void Select(Button button,bool animate){startLeft=left;startWidth=width;targetLeft=button.Left+16;targetWidth=Math.Max(8,button.Width-32);if(animate&&Visible&&ProfileMotion.Allowed&&width>0){watch.Restart();timer.Start();}else{timer.Stop();left=targetLeft;width=targetWidth;Invalidate();}}
    protected override void OnPaintBackground(PaintEventArgs e){if(ProfileSkin.Liquid)ProfileSkin.Canvas(this,e.Graphics);else base.OnPaintBackground(e);}
    public void StopMotion(){timer.Stop();left=targetLeft;width=targetWidth;Invalidate();}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);if(width>0)using(var brush=new SolidBrush(ProfileTheme.Accent))using(var path=ProfileMotion.Round(new RectangleF(left,Height-4,width,3),1.5f))e.Graphics.FillPath(brush,path);}
    protected override void OnVisibleChanged(EventArgs e){base.OnVisibleChanged(e);if(!Visible)StopMotion();}
    protected override void Dispose(bool disposing){if(disposing)timer.Dispose();base.Dispose(disposing);}
}
public sealed class ProfileWrap : FlowLayoutPanel {
    public bool Editorial;public int ItemWidth=220;public int MaximumColumns=2;bool reflow;
    public ProfileWrap(){AutoSize=false;WrapContents=true;Dock=DockStyle.Top;Margin=Padding.Empty;}
    protected override void OnSizeChanged(EventArgs e){base.OnSizeChanged(e);Reflow();}
    protected override void OnControlAdded(ControlEventArgs e){base.OnControlAdded(e);Reflow();}
    public void Reflow(){if(reflow||ClientSize.Width<1)return;reflow=true;try{int columns=Math.Max(1,Math.Min(MaximumColumns,ClientSize.Width/(ItemWidth+10)));int width=Math.Max(100,ClientSize.Width/columns-10);var items=Controls.Cast<Control>().Where(c=>(c.Tag as string)!="hidden").ToArray();foreach(var c in items){c.Width=Editorial&&(c.Name=="mode"||c.Name=="next")?ClientSize.Width-10:width;if(Editorial){c.Height=(int)((c.Name=="mode"?112:c.Name=="next"?72:c.Name=="usage"||c.Name=="game"?82:106)*Font.Size/9f);}}if(Editorial){int total=0,rowHeight=0,used=0;foreach(var c in items){if(used>0&&used+c.Width+c.Margin.Horizontal>ClientSize.Width){total+=rowHeight;rowHeight=0;used=0;}used+=c.Width+c.Margin.Horizontal;rowHeight=Math.Max(rowHeight,c.Height+c.Margin.Vertical);}Height=total+rowHeight;return;}int height=items.Length==0?1:(int)Math.Ceiling(items.Length/(double)columns)*(items.Max(c=>c.Height+c.Margin.Vertical));if(Height!=height)Height=height;}finally{reflow=false;}}
}
public sealed class ProfileRow : FlowLayoutPanel {
    bool sizing;
    public ProfileRow(){AutoSize=false;WrapContents=true;Dock=DockStyle.Top;Height=38;Margin=new Padding(0,0,0,5);}
    protected override void OnLayout(LayoutEventArgs e){base.OnLayout(e);if(sizing)return;sizing=true;try{int bottom=Controls.Count==0?1:Controls.Cast<Control>().Max(c=>c.Bottom+c.Margin.Bottom)+Padding.Bottom;if(Height!=bottom)Height=bottom;}finally{sizing=false;}}
}
public sealed class ProfileMetric : ProfileSurface {
    public bool Featured,Quiet;
    protected override void OnPaintBackground(PaintEventArgs e){if(ProfileSkin.Liquid){base.OnPaintBackground(e);return;}if(!Featured){base.OnPaintBackground(e);return;}e.Graphics.Clear(Parent==null?ProfileTheme.Background:Parent.BackColor);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var path=ProfileMotion.Round(new RectangleF(0,0,Width-1,Height-1),14))using(var brush=new LinearGradientBrush(ClientRectangle,ProfileTheme.Dark?Color.FromArgb(36,63,83):Color.FromArgb(223,240,248),ProfileTheme.Dark?Color.FromArgb(42,47,73):Color.FromArgb(237,233,252),25)){e.Graphics.FillPath(brush,path);}using(var pen=new Pen(Color.FromArgb(32,ProfileTheme.Accent),12)){e.Graphics.DrawArc(pen,Width-125,-40,160,160,50,260);}}
    protected override void OnPaint(PaintEventArgs e){if(!Featured&&!Quiet)base.OnPaint(e);}
    protected override void OnLayout(LayoutEventArgs e){base.OnLayout(e);if(Name=="next"){Caption.Dock=Value.Dock=Context.Dock=DockStyle.None;float factor=Font.Size/9f;Caption.SetBounds((int)(14*factor),(int)(8*factor),Width/2,(int)(20*factor));Value.SetBounds(Width/2,(int)(7*factor),Width/2-(int)(14*factor),(int)(27*factor));Value.TextAlign=ContentAlignment.MiddleRight;Context.SetBounds((int)(14*factor),(int)(36*factor),Width-(int)(28*factor),(int)(22*factor));}}

    public readonly Label Caption=new Label(),Value=new Label(),Context=new Label();
    public ProfileMetric(string title){Height=106;Caption.Text=title;Caption.Dock=DockStyle.Top;Caption.Height=21;Caption.Tag="muted";Value.Dock=DockStyle.Top;Value.Height=34;Value.Font=new Font("Microsoft YaHei UI",20,FontStyle.Bold);Value.AutoEllipsis=true;Context.Dock=DockStyle.Fill;Context.Tag="muted";Context.AutoEllipsis=true;Controls.Add(Context);Controls.Add(Value);Controls.Add(Caption);Value.Text="—";}
    public void Set(string value,string context){Value.Text=value;Context.Text=context;Value.ForeColor=ProfileTheme.Accent;}
}
public sealed class ProfileAIStat : ProfileSurface {
    public readonly Label Caption=new Label(),Value=new Label(),Context=new Label();
    public double Fraction;public bool Composition;
    readonly ProfileHoverTip tip;
    public ProfileAIStat(string title){
        Height=128;Padding=Padding.Empty;AccessibleRole=AccessibleRole.Grouping;
        Caption.Text=title;Caption.Tag=Context.Tag="muted";
        Value.Text="—";Value.Font=new Font("Microsoft YaHei UI",24,FontStyle.Bold);
        foreach(var label in new[]{Caption,Value,Context}){label.AutoEllipsis=true;Controls.Add(label);}
        tip=new ProfileHoverTip(this);SizeChanged+=(s,e)=>PerformLayout();
    }
    public void Set(string title,string value,string context,double fraction,string detail){
        Caption.Text=title;Value.Text=value;Context.Text=context;Fraction=Math.Max(0,Math.Min(1,fraction));
        AccessibleName=title;AccessibleDescription=detail;tip.Update(detail);Invalidate();
    }
    protected override void OnLayout(LayoutEventArgs e){base.OnLayout(e);if(Caption==null)return;float f=Font.Size/9f;int pad=(int)(14*f),width=Math.Max(1,Width-pad*2);Caption.SetBounds(pad,(int)(12*f),width,(int)(21*f));Value.SetBounds(pad,(int)(31*f),width,(int)(50*f));Context.SetBounds(pad,(int)(83*f),width,(int)(20*f));}
    protected override void OnPaint(PaintEventArgs e){
        base.OnPaint(e);float f=Font.Size/9f;var track=new RectangleF(14*f,Height-15*f,Math.Max(1,Width-28*f),5*f);
        Color codex=ProfileTheme.Dark?Color.FromArgb(86,209,173):Color.FromArgb(32,139,111),claude=ProfileTheme.Dark?Color.FromArgb(250,185,88):Color.FromArgb(204,125,32);
        using(var path=ProfileMotion.Round(track,2*f))using(var brush=new SolidBrush(Composition?claude:ProfileTheme.Border))e.Graphics.FillPath(brush,path);
        if(Fraction>0)using(var path=ProfileMotion.Round(new RectangleF(track.X,track.Y,(float)(track.Width*Fraction),track.Height),2*f))using(var brush=new SolidBrush(Composition?codex:ProfileTheme.Accent))e.Graphics.FillPath(brush,path);
    }
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
}
public sealed class ProfileScheduleCanvas : Control {
    public List<ProfileScheduleSlot> Slots=new List<ProfileScheduleSlot>();public DateTime WeekStart=DateTime.Today;
    readonly ProfileHoverTip tip;readonly List<Tuple<RectangleF,ProfileScheduleSlot>> hit=new List<Tuple<RectangleF,ProfileScheduleSlot>>();
    public event EventHandler<ProfileWorkspaceCommand> Selected;
    public ProfileScheduleCanvas(){DoubleBuffered=true;Height=470;Dock=DockStyle.Top;AccessibleName="七日设备任务时间轴";SetStyle(ControlStyles.Selectable,true);TabStop=true;tip=new ProfileHoverTip(this);}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;if(ProfileSkin.Liquid)ProfileSkin.Plot(this,g);else g.Clear(ProfileTheme.Surface);hit.Clear();float left=106,w=Math.Max(1,Width-left-16),row=Math.Max(53,(Height-38)/7f);
        using(var text=new SolidBrush(ProfileTheme.Muted))using(var line=new Pen(ProfileTheme.Border)){
            for(int h=0;h<=24;h+=4){float x=left+w*h/24;string label=h.ToString("00")+":00";float labelWidth=g.MeasureString(label,Font).Width;g.DrawString(label,Font,text,Math.Max(0,Math.Min(Width-labelWidth-2,x-labelWidth/2)),3);g.DrawLine(line,x,27,x,Height-4);}
            string[] days={"周日","周一","周二","周三","周四","周五","周六"};
            for(int d=0;d<7;d++){var date=WeekStart.Date.AddDays(d);float y=30+d*row;if(date.DayOfWeek==DayOfWeek.Saturday||date.DayOfWeek==DayOfWeek.Sunday)using(var fill=new SolidBrush(ProfileTheme.Selection))g.FillRectangle(fill,0,y,Width,row);g.DrawString(date.ToString("MM-dd")+" "+days[(int)date.DayOfWeek],Font,text,8,y+7);g.DrawLine(line,0,y+row-1,Width,y+row-1);
                int lane=0;foreach(var slot in Slots.Where(s=>s.Start.Date<=date&&s.End>date).OrderBy(s=>s.Start)){
                    double a=Math.Max(0,(slot.Start-date).TotalHours),b=Math.Min(24,(slot.End-date).TotalHours);if(b<=a)continue;
                    float height=Math.Max(12,Math.Min(22,(row-22)/Math.Max(1,Slots.Count(s=>s.Start.Date<=date&&s.End>date))));
                    var rect=new RectangleF(left+(float)a*w/24,y+22+lane*height,Math.Max(5,(float)(b-a)*w/24),height-2);lane++;
                    Color color=slot.Conflict?Color.FromArgb(194,72,75):slot.Paused?ProfileTheme.Muted:slot.On?Color.FromArgb(39,143,119):ProfileTheme.Accent;
                    using(var brush=new SolidBrush(Color.FromArgb(slot.Paused?90:190,color)))g.FillRectangle(brush,rect);
                    using(var brush=new SolidBrush(ProfileTheme.Text)){var label=slot.Name+" · "+(slot.On?"开":"关");if(rect.Width>100)g.DrawString(label,Font,brush,rect,new StringFormat{Trimming=StringTrimming.EllipsisCharacter,FormatFlags=StringFormatFlags.NoWrap});}
                    hit.Add(Tuple.Create(rect,slot));
                }
            }
            if(Slots.Count==0)g.DrawString("本周没有任务；选择设备后可添加定时或保持规则",Font,text,left+10,Height/2);
        }
    }
    protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);var item=hit.FirstOrDefault(x=>x.Item1.Contains(e.Location));tip.Update(item==null?"":item.Item2.Device+" · "+item.Item2.Name+"\n"+item.Item2.Start.ToString("MM-dd ddd HH:mm")+" — "+item.Item2.End.ToString("MM-dd ddd HH:mm")+"\n"+item.Item2.Status);}
    protected override void OnMouseClick(MouseEventArgs e){base.OnMouseClick(e);var item=hit.FirstOrDefault(x=>x.Item1.Contains(e.Location));if(item!=null&&Selected!=null)Selected(this,new ProfileWorkspaceCommand("SelectRule",item.Item2.Id));}
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
}
public sealed class ProfileBufferedGrid : DataGridView {
    int batch;public ProfileBufferedGrid(){DoubleBuffered=true;}
    [System.Runtime.InteropServices.DllImport("user32.dll")]static extern IntPtr SendMessage(IntPtr h,int m,IntPtr w,IntPtr l);
    public void BeginBatch(){if(batch++==0){SuspendLayout();if(IsHandleCreated)SendMessage(Handle,11,IntPtr.Zero,IntPtr.Zero);}}
    public void EndBatch(){if(batch==0)return;if(--batch==0){if(IsHandleCreated)SendMessage(Handle,11,new IntPtr(1),IntPtr.Zero);ResumeLayout();Invalidate();}}
}
public static class ProfileGlass {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential,CharSet=System.Runtime.InteropServices.CharSet.Unicode)]struct VersionInfo {public uint Size,Major,Minor,Build,Platform;[System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr,SizeConst=128)]public string ServicePack;}
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]struct Margins {public int Left,Right,Top,Bottom;}
    [System.Runtime.InteropServices.DllImport("ntdll.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]static extern int RtlGetVersion(ref VersionInfo v);
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]static extern int DwmSetWindowAttribute(IntPtr h,int a,ref int v,int size);
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]static extern int DwmExtendFrameIntoClientArea(IntPtr h,ref Margins m);
    public static bool Apply(Form form,bool enabled,int top){try{var version=new VersionInfo{Size=(uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(VersionInfo))};RtlGetVersion(ref version);if(version.Build<22621)return false;bool transparency=Convert.ToInt32(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize","EnableTransparency",1))!=0;bool use=enabled&&transparency&&!SystemInformation.HighContrast;int dark=ProfileTheme.Dark?1:0,type=use?3:1;DwmSetWindowAttribute(form.Handle,20,ref dark,4);int result=DwmSetWindowAttribute(form.Handle,38,ref type,4);var margins=use&&top<0?new Margins{Left=-1,Right=-1,Top=-1,Bottom=-1}:new Margins{Top=use?top:0};return DwmExtendFrameIntoClientArea(form.Handle,ref margins)==0&&result==0&&use;}catch{return false;}}
}
public sealed class ProfileGlassPanel : Panel {
    protected override void OnPaintBackground(PaintEventArgs e){var form=FindForm() as ProfileWorkspaceForm;if(form!=null&&form.GlassActive)e.Graphics.Clear(Color.Transparent);else base.OnPaintBackground(e);}
}
public sealed class ProfileDeferredSurface : ProfileSurface {
    public Action<ProfileSurface> Populate;bool populated;
    public void EnsureContent(){if(populated||Populate==null)return;populated=true;Populate(this);Populate=null;}
    protected override void OnPaint(PaintEventArgs e){EnsureContent();base.OnPaint(e);}
}
public sealed class ProfileWorkspaceForm : Form {
    public event EventHandler<ProfileWorkspaceCommand> Command;
    public readonly Dictionary<string,Panel> Pages=new Dictionary<string,Panel>();
    public readonly Dictionary<string,ProfileMetric> Metrics=new Dictionary<string,ProfileMetric>();
    public readonly Dictionary<string,Button> Navigation=new Dictionary<string,Button>();
    public readonly Label Footer=new Label(),OverviewReason=new Label(),Runtime=new Label(),Quality=new Label(),SelectionInfo=new Label(),TaskInfo=new Label(),GameInfo=new Label();
    public readonly Panel ChartHost=new Panel();public readonly ProfileScheduleCanvas Calendar=new ProfileScheduleCanvas();
    public readonly List<CheckBox> SeriesChecks=new List<CheckBox>();
    public readonly Panel AIChartHost=new Panel();public readonly Label AIPeriodSummary=new Label(),AIStatus=new Label();public readonly ProfileWrap AIStatHost=new ProfileWrap();public readonly ProfileAIStat AITokens=new ProfileAIStat("累计 tokens"),AICost=new ProfileAIStat("累计估算");public readonly TextBox AISearch=new TextBox();public readonly ComboBox AISource,AIClient,AIRange,AIView,AICurrency,AnalysisMode,TrendCurrency,TrendSource;public readonly DataGridView AIGrid;
    public readonly DataGridView Ledger,GameGrid,RuleGrid,GameTotals,GameSessions;
    public readonly TextBox LedgerSearch=new TextBox(),GameSearch=new TextBox();
    public readonly ComboBox DayFilter,SourceFilter,QualityFilter,GameRange;
    public readonly CheckBox CustomDates=new CheckBox{Text="自选日期",AutoSize=true};
    public readonly DateTimePicker FromDate=new DateTimePicker(),ToDate=new DateTimePicker();
    public readonly ProfileInsightsPanel Insights=new ProfileInsightsPanel();
    public readonly Label GameDetail=new Label();
    public readonly ComboBox Range,Group,Theme,TextSize,Room,CalendarDevice;
    public readonly TextBox Search=new TextBox();public readonly CheckBox Favorites=new CheckBox();
    public readonly ProfileWrap MetricHost=new ProfileWrap(),DeviceHost=new ProfileWrap();
    public readonly Dictionary<string,CheckBox> MetricOptions=new Dictionary<string,CheckBox>();
    public bool DeferDevices;public string ActivePage="Overview";public int WeekOffset;bool building=true,adapting,changingPage;
    readonly Panel content=new ProfileSkinPanel(),header=new ProfileGlassPanel();readonly Label heading=new Label(),brand=new Label();readonly float textFactor;
    public readonly ComboBox Skin=Combo(new[]{"液态玻璃","标准","经典毛玻璃"});public readonly Label SkinStatus=new Label();public readonly CheckBox Glass=new CheckBox{Text="系统背景模糊",AutoSize=true,Checked=true};public bool GlassActive {get;private set;}
    static void Material(Control c,bool glass){if(c is Panel && !(c is ProfileSurface) || c is Label)c.BackColor=glass || c is Label && c.Parent is ProfileMetric && ((ProfileMetric)c.Parent).Featured?Color.Transparent:(c.Parent==null?ProfileTheme.Background:c.Parent.BackColor);foreach(Control child in c.Controls)Material(child,glass); }
    public void ApplyGlass(){if(!IsHandleCreated)return;ProfileSkin.SystemBlur=Glass.Checked;Glass.Visible=Glass.Enabled=ProfileSkin.Kind!="Standard";GlassActive=ProfileGlass.Apply(this,Glass.Checked&&ProfileSkin.Kind!="Standard",ProfileSkin.Kind=="Liquid"?0:header.Height+NavigationStrip.Height);if(ProfileSkin.Liquid){ProfileTheme.Style(this);}else{Material(content,false);Material(header,GlassActive);Material(NavigationStrip,GlassActive);Footer.BackColor=ProfileTheme.Background;}SkinStatus.Text=SystemInformation.HighContrast?"高对比度 · 使用系统实底":ProfileSkin.Kind=="Liquid"?"液态玻璃 · "+(GlassActive?"标题栏系统模糊":"清晰材质回退"):ProfileSkin.Kind=="ClassicGlass"?"经典毛玻璃 · 标题与导航":"标准 · 清晰实底";Invalidate(true);}
    protected override void OnShown(EventArgs e){base.OnShown(e);ApplyGlass();}
    protected override void OnPaintBackground(PaintEventArgs e){if(ProfileSkin.Liquid)ProfileSkin.Canvas(this,e.Graphics);else if(GlassActive)e.Graphics.Clear(Color.Transparent);else base.OnPaintBackground(e);}
    public readonly ProfileNavigation NavigationStrip=new ProfileNavigation();
    public readonly CheckBox Motion=new CheckBox{Text="轻量动画",AutoSize=true,Checked=true};
    public readonly Dictionary<string,ProfileDisclosure> Sections=new Dictionary<string,ProfileDisclosure>();
    readonly Dictionary<string,ProfileSurface> deviceCards=new Dictionary<string,ProfileSurface>();
    readonly ToolTip tips=new ToolTip{AutoPopDelay=15000,InitialDelay=500};
    public ProfileWorkspaceForm():this(100){}
    public ProfileWorkspaceForm(int textScale){
        textFactor=textScale==125?1.25f:textScale==150?1.5f:1f;
        Text="PowerProfile";Font=new Font("Microsoft YaHei UI",9F);AutoScaleMode=AutoScaleMode.Dpi;ClientSize=new Size(540,720);MinimumSize=new Size(436,596);StartPosition=FormStartPosition.CenterScreen;KeyPreview=true;
        SetStyle(ControlStyles.OptimizedDoubleBuffer|ControlStyles.AllPaintingInWmPaint,true);
        Controls.Add(content);content.Dock=DockStyle.Fill;content.Padding=new Padding(16,0,8,0);
        header.Dock=DockStyle.Top;header.Height=52;header.Padding=new Padding(18,9,18,0);brand.Text="PowerProfile";brand.Font=new Font("Microsoft YaHei UI",15,FontStyle.Bold);brand.AutoSize=true;brand.Location=new Point(18,13);header.Controls.Add(brand);
        heading.Font=new Font("Microsoft YaHei UI",9);heading.ForeColor=ProfileTheme.Muted;heading.AutoSize=false;heading.TextAlign=ContentAlignment.MiddleRight;header.Controls.Add(heading);Controls.Add(header);
        NavigationStrip.Dock=DockStyle.Top;NavigationStrip.Height=43;NavigationStrip.Padding=new Padding(12,0,12,0);Controls.Add(NavigationStrip);
        string[][] destinations={new[]{"Overview","总览","总览"},new[]{"Energy","趋势","综合趋势"},new[]{"AI","AI","AI 用量与费用"},new[]{"Games","游戏","游戏记录"},new[]{"Devices","设备","设备"},new[]{"Automation","任务","自动化"},new[]{"Settings","设置","设置"}};
        foreach(var entry in destinations){string key=entry[0];var b=Button(entry[1],"Navigate",key);b.AccessibleName=entry[2];b.AutoSize=false;b.Size=new Size(80,34);b.Margin=Padding.Empty;NavigationStrip.Controls.Add(b);Navigation[key]=b;var page=new ProfileSkinPanel{Dock=DockStyle.Fill,AutoScroll=true,Padding=new Padding(0,10,6,8),Visible=false};Pages[key]=page;content.Controls.Add(page);}
        Footer.Dock=DockStyle.Bottom;Footer.Height=26;Footer.Padding=new Padding(16,3,12,2);Footer.Tag="muted";Footer.AutoEllipsis=true;Footer.Text="正在读取…";Controls.Add(Footer);Footer.TextChanged+=(s,e)=>tips.SetToolTip(Footer,Footer.Text);
        MetricHost.Editorial=true;var home=Column(Pages["Overview"]);home.Controls.Add(Row(Button("自动","Auto"),Button("静音","Idle"),Button("均衡","Balanced"),Button("游戏","Game")));
        foreach(var entry in new[]{new[]{"mode","电源档位"},new[]{"power","插座输入"},new[]{"cost","今日电费"},new[]{"usage","电脑使用"},new[]{"game","游戏时长"},new[]{"next","设备任务"}}){var card=new ProfileMetric(entry[1]);card.Name=entry[0];if(entry[0]=="next")card.Value.Font=new Font("Microsoft YaHei UI",14,FontStyle.Bold);card.Featured=entry[0]=="mode";if(card.Featured){card.Value.Height=46;card.Value.Font=new Font("Microsoft YaHei UI",26,FontStyle.Bold);}card.Quiet=entry[0]=="usage"||entry[0]=="game";Metrics[entry[0]]=card;MetricHost.Controls.Add(card);}home.Controls.Add(MetricHost);
        home.Controls.Add(Row(Button("硬件监测","Hardware"),Button("连接设备","Connection"),Button("查看日志","Logs")));
        PrepareDetail(OverviewReason);PrepareDetail(Runtime);Runtime.Text="正在读取运行状态…";OverviewReason.Text="暂无新的档位识别记录。";AddSection(home,"Runtime","运行详情",Runtime,OverviewReason);
        var energy=Column(Pages["Energy"]);AnalysisMode=Combo(new[]{"用电与时长","用电 + AI tokens","用电 + AI 费用"});AnalysisMode.Width=180;AnalysisMode.SelectedIndex=0;TrendCurrency=Combo(new[]{"USD","CNY"});TrendCurrency.Width=75;TrendCurrency.SelectedIndex=0;TrendSource=Combo(new[]{"客户端日志","CC Switch","自动合并"});TrendSource.Width=115;TrendSource.SelectedIndex=0;energy.Controls.Add(Row(AnalysisMode,TrendSource,TrendCurrency));TrendCurrency.SelectedIndexChanged+=(s,e)=>{if(AICurrency!=null)AICurrency.SelectedIndex=TrendCurrency.SelectedIndex;Emit("AIFilter");};TrendSource.SelectedIndexChanged+=(s,e)=>{if(AISource!=null)AISource.SelectedIndex=TrendSource.SelectedIndex;Emit("AIFilter");};AnalysisMode.SelectedIndexChanged+=(s,e)=>Emit("AIFilter");Range=Combo(new[]{"近 7 天","近 30 天","近 90 天"});Range.SelectedIndex=1;Range.Width=125;Group=Combo(new[]{"按日","按周","按月"});Group.SelectedIndex=0;Group.Width=90;
        energy.Controls.Add(Row(Range,Group,MenuButton("更多",new[]{new[]{"连接与电价","Connection"},new[]{"补录米家历史","Cloud"},new[]{"刷新采样","RefreshEnergy"},new[]{"恢复图表区间","ResetChart"},new[]{"导出图表 PNG","ExportPng"},new[]{"导出当前明细 CSV","ExportCsv"},new[]{"导出所选月份报告","ExportReport"}})));
        var series=Row();string[] seriesNames={"电费","使用","高功耗","游戏"};for(int i=0;i<4;i++){int n=i;var check=new CheckBox{Text=seriesNames[i],Checked=true,AutoSize=true,Margin=new Padding(0,4,14,4)};check.CheckedChanged+=(s,e)=>Emit("Series",n+":"+check.Checked);SeriesChecks.Add(check);series.Controls.Add(check);}energy.Controls.Add(series);
        ChartHost.Height=220;ChartHost.Margin=new Padding(0,0,0,8);energy.Controls.Add(ChartHost);tips.SetToolTip(ChartHost,"滚轮缩放 · 拖动选择区间 · 点击联动明细");
        LedgerSearch.Width=180;LedgerSearch.AccessibleName="搜索日期、星期、游戏或来源";DayFilter=Combo(new[]{"全部日期","周一至周五","周六与周日"});SourceFilter=Combo(new[]{"全部来源","米家历史","本机功率积分","无电量记录"});QualityFilter=Combo(new[]{"全部记录","含会话推算","缺少电量"});
        foreach(var picker in new[]{FromDate,ToDate}){picker.Format=DateTimePickerFormat.Custom;picker.CustomFormat="yyyy-MM-dd dddd";picker.Width=190;picker.Value=DateTime.Today;picker.Enabled=false;}FromDate.Value=DateTime.Today.AddDays(-29);
        DayFilter.SelectedIndex=SourceFilter.SelectedIndex=QualityFilter.SelectedIndex=0;
        AddSection(energy,"EnergyFilters","筛选与显示",Row(new Label{Text="搜索",AutoSize=true},LedgerSearch),Row(DayFilter,SourceFilter,QualityFilter),Row(CustomDates,Button("显示列","LedgerColumns")),Row(FromDate,ToDate));
        Ledger=Grid(new[]{"日期 / 星期","电量 kWh","电费","使用时长","高功耗","游戏","电量来源","Codex tokens","Claude tokens","Codex 估算费用","Claude 估算费用"});Ledger.Height=240;Ledger.Columns[0].MinimumWidth=132;Ledger.Columns[0].FillWeight=140;foreach(int i in new[]{1,4,6,7,8,9,10})Ledger.Columns[i].Visible=false;energy.Controls.Add(Ledger);
        PrepareDetail(Quality);PrepareDetail(SelectionInfo);AddSection(energy,"EnergyEvidence","所选日期 · 数据依据",SelectionInfo,Quality);
        Ledger.SelectionChanged+=(s,e)=>Emit("LedgerSelection",Ledger.CurrentRow==null?"":Convert.ToString(Ledger.CurrentRow.Tag));foreach(DataGridViewColumn c in Ledger.Columns)c.SortMode=c.Index<7?DataGridViewColumnSortMode.Programmatic:DataGridViewColumnSortMode.NotSortable;Ledger.ColumnHeaderMouseClick+=(s,e)=>{if(e.ColumnIndex<7)Emit("LedgerSort",e.ColumnIndex.ToString());};
        LedgerSearch.TextChanged+=(s,e)=>Emit("InsightsFilter");foreach(var combo in new[]{DayFilter,SourceFilter,QualityFilter})combo.SelectedIndexChanged+=(s,e)=>Emit("InsightsFilter");CustomDates.CheckedChanged+=(s,e)=>{FromDate.Enabled=ToDate.Enabled=CustomDates.Checked;Emit("InsightsFilter");};FromDate.ValueChanged+=(s,e)=>Emit("InsightsFilter");ToDate.ValueChanged+=(s,e)=>Emit("InsightsFilter");
        energy.Controls.Add(Insights);Insights.Metric.SelectedIndexChanged+=(s,e)=>Emit("InsightsFilter");Insights.Heatmap.Selected+=(s,e)=>Emit(e.Action,e.Id);Range.SelectedIndexChanged+=(s,e)=>Emit("EnergyRange");Group.SelectedIndexChanged+=(s,e)=>Emit("EnergyRange");
        var ai=Column(Pages["AI"]);AISource=Combo(new[]{"客户端日志","CC Switch","自动合并"});AISource.Width=125;AISource.SelectedIndex=2;AIClient=Combo(new[]{"全部","Codex","Claude Code"});AIClient.Width=108;AIClient.SelectedIndex=0;AIRange=Combo(new[]{"近 7 天","近 30 天","近 90 天","近 400 天","全部历史"});AIRange.Width=108;AIRange.SelectedIndex=4;
        AISource.AccessibleName="AI 记录来源";AIClient.AccessibleName="AI 客户端";AIRange.AccessibleName="AI 日期范围";AITokens.Composition=true;AIStatHost.ItemWidth=210;AIStatHost.Controls.Add(AITokens);AIStatHost.Controls.Add(AICost);ai.Controls.Add(AIStatHost);
        AIView=Combo(new[]{"Token 趋势","估算费用","独立支出"});AIView.Width=125;AIView.SelectedIndex=0;AICurrency=Combo(new[]{"USD","CNY"});AICurrency.SelectedIndex=0;AICurrency.Width=70;AICurrency.AccessibleName="AI 费用币种";AIView.AccessibleName="AI 统计视图";ai.Controls.Add(Row(AIView,AICurrency,MenuButton("更多",new[]{new[]{"设置模型单价","AIPrice"},new[]{"记录订阅 / 充值","AIExpense"},new[]{"导出当前 CSV","AIExport"},new[]{"本地来源接入","AISources"},new[]{"切换完整字段","AIColumns"}})));AIPeriodSummary.AutoSize=true;AIPeriodSummary.Tag="muted";AIPeriodSummary.Margin=new Padding(0,4,0,8);ai.Controls.Add(AIPeriodSummary);
        AIChartHost.Height=180;ai.Controls.Add(AIChartHost);AISearch.Width=210;AISearch.AccessibleName="搜索 AI 模型或日期";AddSection(ai,"AIFilters","筛选与来源",Row(AIRange,AIClient,AISource),Row(new Label{Text="搜索",AutoSize=true,Margin=new Padding(0,7,10,0)},AISearch));
        AIGrid=Grid(new[]{"日期 / 星期","客户端","模型","Tokens","费用 / 币种","新增 / 读缓存 / 写缓存 / 输出","计价覆盖"});AIGrid.Height=260;foreach(int c in new[]{2,5,6})AIGrid.Columns[c].Visible=false;ai.Controls.Add(AIGrid);PrepareDetail(AIStatus);AddSection(ai,"AIStatus","接入状态与统计口径",AIStatus);
        AISource.SelectedIndexChanged+=(s,e)=>{TrendSource.SelectedIndex=AISource.SelectedIndex;Emit("AIFilter");};AICurrency.SelectedIndexChanged+=(s,e)=>{TrendCurrency.SelectedIndex=AICurrency.SelectedIndex;Emit("AIFilter");};foreach(var combo in new[]{AIClient,AIRange,AIView})combo.SelectedIndexChanged+=(s,e)=>Emit("AIFilter");AISearch.TextChanged+=(s,e)=>Emit("AIFilter");
        var games=Column(Pages["Games"]);GameRange=Combo(new[]{"近 7 天","近 30 天","近 90 天","近 400 天"});GameRange.SelectedIndex=1;GameRange.Width=120;GameSearch.Width=150;GameSearch.AccessibleName="搜索游戏名称";
        games.Controls.Add(Row(GameRange,new Label{Text="搜索",AutoSize=true,Margin=new Padding(0,7,5,0)},GameSearch,MenuButton("更多",new[]{new[]{"查看全部游戏","GamesFilter"},new[]{"导出会话 CSV","ExportGames"},new[]{"切换完整分析表","GameColumns"}})));
        GameTotals=Grid(new[]{"游戏名称","记录时长","片段数","功率覆盖","采样均功率 W","采样电费"});GameTotals.Height=200;GameTotals.Columns[0].MinimumWidth=150;GameTotals.Columns[0].FillWeight=160;GameTotals.Columns[0].DefaultCellStyle.WrapMode=DataGridViewTriState.True;GameTotals.RowTemplate.Height=44;foreach(int i in new[]{3,4,5})GameTotals.Columns[i].Visible=false;games.Controls.Add(GameTotals);
        AddText(games,"会话",12,true);GameSessions=Grid(new[]{"游戏名称","开始 / 星期","结束 / 星期","时长","功率覆盖","采样均功率 W","采样电费","依据"});GameSessions.Height=250;GameSessions.Columns[0].MinimumWidth=135;GameSessions.Columns[1].MinimumWidth=145;GameSessions.Columns[3].MinimumWidth=95;GameSessions.RowTemplate.Height=56;foreach(DataGridViewColumn c in GameSessions.Columns)c.DefaultCellStyle.WrapMode=DataGridViewTriState.True;foreach(int i in new[]{2,4,5,6,7})GameSessions.Columns[i].Visible=false;games.Controls.Add(GameSessions);
        PrepareDetail(GameInfo);PrepareDetail(GameDetail);AddSection(games,"GameEvidence","会话详情与统计口径",GameDetail,GameInfo,MenuButton("会话显示列",new[]{new[]{"切换完整会话表","GameColumns"}}));
        GameTotals.SelectionChanged+=(s,e)=>Emit("GameSelect",GameTotals.CurrentRow==null?"":Convert.ToString(GameTotals.CurrentRow.Tag));GameSessions.SelectionChanged+=(s,e)=>Emit("GameSessionSelect",GameSessions.CurrentRow==null?"":Convert.ToString(GameSessions.CurrentRow.Tag));GameRange.SelectedIndexChanged+=(s,e)=>Emit("GamesFilter");GameSearch.TextChanged+=(s,e)=>Emit("GamesFilter");
        GameGrid=Grid(new[]{"日期 / 星期","游戏名称","游戏时长","覆盖 / 依据"});GameGrid.Height=220;GameGrid.Columns[3].Visible=false;AddSection(games,"GameDaily","逐日记录",GameGrid);
        var devices=Column(Pages["Devices"]);Search.Width=155;Search.AccessibleName="搜索设备名称或型号";Room=Combo(new[]{"全部分组"});Room.Width=120;Room.SelectedIndex=0;Favorites.Text="收藏";Favorites.AutoSize=true;
        devices.Controls.Add(Row(new Label{Text="搜索",AutoSize=true,Margin=new Padding(0,7,5,0)},Search,Room,Favorites));devices.Controls.Add(Row(Button("同步设备","RefreshDevices"),Button("接入设备","Connection")));DeviceHost.ItemWidth=260;DeviceHost.MaximumColumns=1;
        DeviceHost.ControlAdded+=(s,e)=>{if(textFactor!=1&&e.Control is ProfileSurface){var fonts=new Dictionary<Control,Font>();CaptureFonts(e.Control,fonts);e.Control.Scale(new SizeF(textFactor,textFactor));foreach(var item in fonts)item.Key.Font=new Font(item.Value.FontFamily,item.Value.Size*textFactor,item.Value.Style);DeviceHost.Reflow();}};devices.Controls.Add(DeviceHost);Search.TextChanged+=(s,e)=>Emit("FilterDevices");Room.SelectedIndexChanged+=(s,e)=>Emit("FilterDevices");Favorites.CheckedChanged+=(s,e)=>Emit("FilterDevices");
        var automation=Column(Pages["Automation"]);CalendarDevice=Combo(new[]{"全部设备"});CalendarDevice.SelectedIndex=0;CalendarDevice.Width=170;automation.Controls.Add(Row(Button("‹","Week","-1"),Button("本周","Week","0"),Button("›","Week","1"),CalendarDevice));automation.Controls.Add(Row(Button("添加任务","NewRule"),Button("中枢启停","ToggleHub")));
        Calendar.Height=370;automation.Controls.Add(Calendar);Calendar.Selected+=(s,e)=>Emit(e.Action,e.Id);CalendarDevice.SelectedIndexChanged+=(s,e)=>Emit("CalendarFilter");RuleGrid=Grid(new[]{"任务","设备","执行安排","下次 / 状态"});RuleGrid.Height=210;RuleGrid.Columns[1].Visible=false;
        AddSection(automation,"Rules","任务列表与编辑",RuleGrid,Row(Button("编辑","EditRule"),Button("启用 / 暂停","ToggleRule"),Button("移除","RemoveRule")));PrepareDetail(TaskInfo);AddSection(automation,"TaskInfo","运行状态与安排",TaskInfo);
        var settings=Column(Pages["Settings"]);AddText(settings,"外观",12,true);Theme=Combo(new[]{"跟随系统","浅色","深色"});Theme.Width=120;Theme.SelectedIndex=0;TextSize=Combo(new[]{"标准 100%","较大 125%","大号 150%"});TextSize.Width=125;TextSize.SelectedIndex=textScale==150?2:textScale==125?1:0;
        Skin.Width=155;Skin.AccessibleName="界面皮肤";Skin.SelectedIndex=ProfileSkin.Kind=="Liquid"?0:ProfileSkin.Kind=="ClassicGlass"?2:1;settings.Controls.Add(Row(Skin,Theme));settings.Controls.Add(Row(TextSize,Motion,Glass));SkinStatus.AutoSize=true;SkinStatus.Tag="muted";settings.Controls.Add(SkinStatus);Skin.SelectedIndexChanged+=(s,e)=>{SetSkin(Skin.SelectedIndex);Emit("Skin",ProfileSkin.Kind);};Glass.CheckedChanged+=(s,e)=>{ApplyGlass();Emit("Glass",Glass.Checked.ToString());};Theme.SelectedIndexChanged+=(s,e)=>Emit("Theme",Theme.SelectedIndex.ToString());TextSize.SelectedIndexChanged+=(s,e)=>Emit("TextSize",new[]{100,125,150}[TextSize.SelectedIndex].ToString());Motion.CheckedChanged+=(s,e)=>{ProfileMotion.Enabled=Motion.Checked;if(!Motion.Checked)NavigationStrip.StopMotion();Emit("Motion",Motion.Checked.ToString());};
        var options=Row();foreach(var entry in Metrics){string key=entry.Key;var check=new CheckBox{Text=entry.Value.Caption.Text,Checked=true,AutoSize=true,Margin=new Padding(0,5,14,6)};check.CheckedChanged+=(s,e)=>Emit("Metric",key+":"+check.Checked);MetricOptions[key]=check;options.Controls.Add(check);}AddSection(settings,"Cards","总览卡片",options);
        AddText(settings,"电源",12,true);settings.Controls.Add(Row(Button("档位与识别","AdvancedSettings"),Button("省电计划","PlanSettings"),Button("C-state 保护","CState")));
        AddText(settings,"连接与维护",12,true);settings.Controls.Add(Row(Button("连接自检","Connection"),Button("指南与更新","Welcome"),Button("运行日志","Logs")));
        AddSection(settings,"About","后台运行说明",Label("关闭窗口后托盘与已启用的设备任务继续运行。设备任务需要电脑唤醒并联网。暂停任务请在任务页停用中枢。",9));
        SizeChanged+=(s,e)=>Adapt();KeyDown+=(s,e)=>{if(e.Control&&e.KeyCode==Keys.D1)Navigate("Overview");if(e.Control&&e.KeyCode==Keys.D2)Navigate("Energy");if(e.Control&&e.KeyCode==Keys.D3)Navigate("Devices");if(e.Control&&e.KeyCode==Keys.D4)Navigate("Automation");if(e.KeyCode==Keys.F5)Emit("Refresh");};
        content.BringToFront();Footer.SendToBack();NavigationStrip.SendToBack();header.SendToBack();
        if(textScale==125||textScale==150){float factor=textScale/100f;var fonts=new Dictionary<Control,Font>();CaptureFonts(this,fonts);Scale(new SizeF(factor,factor));foreach(var item in fonts)item.Key.Font=new Font(item.Value.FontFamily,item.Value.Size*factor,item.Value.Style);MetricHost.ItemWidth=(int)(220*factor);DeviceHost.ItemWidth=(int)(260*factor);AIStatHost.ItemWidth=(int)(210*factor);}
        SystemEvents.UserPreferenceChanged+=SystemThemeChanged;building=false;Navigate("Overview");Adapt();
    }
    static void PrepareDetail(Label label){label.AutoSize=true;label.MaximumSize=new Size(480,0);label.Margin=new Padding(0,5,0,8);label.Tag="muted";}
    ProfileDisclosure AddSection(FlowLayoutPanel parent,string key,string title,params Control[] controls){var section=new ProfileDisclosure(title);section.Add(controls);parent.Controls.Add(section);Sections[key]=section;return section;}
    Button MenuButton(string text,string[][] entries){var button=Button(text+" ▾","");button.Click+=(s,e)=>{var menu=new ContextMenuStrip();foreach(var item in entries){string action=item[1];var choice=menu.Items.Add(item[0]);choice.Click+=(a,b)=>Emit(action);}menu.Closed+=(a,b)=>menu.Dispose();menu.Show(button,new Point(0,button.Height));};return button;}
    public void ShowSection(string key){if(Sections.ContainsKey(key))Sections[key].Expanded=true;}
    static void CaptureFonts(Control c,Dictionary<Control,Font> fonts){fonts[c]=c.Font;foreach(Control child in c.Controls)CaptureFonts(child,fonts);}
    public static void ScaleDialog(Form form,int percent){if(percent!=125&&percent!=150)return;float factor=percent/100f;var fonts=new Dictionary<Control,Font>();CaptureFonts(form,fonts);form.Scale(new SizeF(factor,factor));foreach(var item in fonts)item.Key.Font=new Font(item.Value.FontFamily,item.Value.Size*factor,item.Value.Style);form.AutoScroll=true;form.AutoScrollMinSize=form.ClientSize;var area=Screen.FromControl(form).WorkingArea;form.Size=new Size(Math.Min(form.Width,area.Width-30),Math.Min(form.Height,area.Height-40));}
    void SystemThemeChanged(object sender,UserPreferenceChangedEventArgs e){if(IsDisposed)return;try{BeginInvoke((Action)(()=>{SetTheme(Theme.SelectedIndex);}));}catch{}}
    public void Emit(string action,string id=""){if(!building&&Command!=null)Command(this,new ProfileWorkspaceCommand(action,id));}
    public static Label Label(string text,float size=10,bool bold=false){return new Label{Text=text,AutoSize=true,Font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular),Margin=new Padding(0,6,0,7)};}
    Button Button(string text,string action,string id=""){var b=new ProfileActionButton{Text=text,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,MinimumSize=new Size(0,32),Margin=new Padding(0,2,8,5)};if(!String.IsNullOrEmpty(action))b.Click+=(s,e)=>Emit(action,id);return b;}
    public static ComboBox Combo(string[] choices){var c=new ComboBox{DropDownStyle=ComboBoxStyle.DropDownList,Width=145,Margin=new Padding(0,4,12,7)};c.Items.AddRange(choices);return c;}
    static FlowLayoutPanel Row(params Control[] controls){var row=new ProfileRow();foreach(var c in controls)row.Controls.Add(c);return row;}
    static FlowLayoutPanel Column(Panel parent){var col=new FlowLayoutPanel{FlowDirection=FlowDirection.TopDown,WrapContents=false,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,Location=new Point(0,0),Width=parent.ClientSize.Width};col.ControlAdded+=(s,e)=>{e.Control.Dock=DockStyle.None;e.Control.Anchor=AnchorStyles.Top|AnchorStyles.Left;e.Control.Width=Math.Max(100,col.Width-8);};parent.Controls.Add(col);parent.SizeChanged+=(s,e)=>{int width=Math.Max(100,parent.ClientSize.Width-22);col.MinimumSize=Size.Empty;col.MaximumSize=new Size(width,0);col.MinimumSize=new Size(width,0);col.Width=width;foreach(Control c in col.Controls){c.Width=width-8;var f=c as ProfileWrap;if(f!=null)f.Reflow();if(c is Label)((Label)c).MaximumSize=new Size(width-8,0);}};return col;}
    static void AddText(FlowLayoutPanel parent,string text,float size,bool bold){var l=Label(text,size,bold);l.MaximumSize=new Size(1100,0);if(!bold)l.Tag="muted";parent.Controls.Add(l);}
    public static DataGridView Grid(string[] columns){var grid=new ProfileBufferedGrid{ReadOnly=true,AllowUserToAddRows=false,AllowUserToDeleteRows=false,AllowUserToResizeRows=false,RowHeadersVisible=false,MultiSelect=false,SelectionMode=DataGridViewSelectionMode.FullRowSelect,AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill,BorderStyle=BorderStyle.None,EnableHeadersVisualStyles=false,ColumnHeadersHeight=36};grid.RowTemplate.Height=37;foreach(var name in columns){int i=grid.Columns.Add("c"+grid.Columns.Count,name);grid.Columns[i].MinimumWidth=75;}grid.ClipboardCopyMode=DataGridViewClipboardCopyMode.EnableAlwaysIncludeHeaderText;return grid;}
    public void Navigate(string key){if(!Pages.ContainsKey(key))return;bool changed=ActivePage!=key;if(!changed&&!building&&Pages[key].Visible){Emit("Page",key);return;}ActivePage=key;foreach(var entry in Pages)entry.Value.Visible=entry.Key==key;Pages[key].BringToFront();heading.Text=Navigation[key].AccessibleName;foreach(var entry in Navigation){var button=entry.Value as ProfileActionButton;if(button!=null){button.Selected=entry.Key==key;button.Invalidate();}}changingPage=changed;try{Adapt();}finally{changingPage=false;}NavigationStrip.Select(Navigation[key],changed);Emit("Page",key);}
    void Adapt(){if(adapting)return;adapting=true;try{heading.SetBounds(Math.Max(180,header.Width-180),(int)(14*textFactor),150,(int)(25*textFactor));int index=0,available=NavigationStrip.ClientSize.Width-NavigationStrip.Padding.Horizontal;foreach(var b in Navigation.Values){int a=NavigationStrip.Padding.Left+available*index/Navigation.Count,z=NavigationStrip.Padding.Left+available*(index+1)/Navigation.Count;b.SetBounds(a,0,z-a-3,NavigationStrip.Height-8);index++;}foreach(var p in Pages.Values.Where(p=>p.Visible)){var col=p.Controls.OfType<FlowLayoutPanel>().FirstOrDefault();if(col!=null){int width=Math.Max(100,p.ClientSize.Width-22);col.MinimumSize=Size.Empty;col.MaximumSize=new Size(width,0);col.MinimumSize=new Size(width,0);col.Width=width;foreach(Control c in col.Controls){c.Dock=DockStyle.None;c.Width=width-4;if(c is Label)((Label)c).MaximumSize=new Size(width-4,0);}col.PerformLayout();}}MetricHost.Reflow();DeviceHost.Reflow();Calendar.Invalidate();if(!changingPage&&Navigation.ContainsKey(ActivePage)&&!NavigationStrip.Animating)NavigationStrip.Select(Navigation[ActivePage],false);}finally{adapting=false;}}
    public static Size PortraitSize(Size available){int height=Math.Max(1,Math.Min(720,Math.Min(available.Height,(int)(available.Width/0.75))));return new Size((int)Math.Round(height*.75),height);}
    public void SetSkin(int index){ProfileSkin.Set(index==0?"Liquid":index==2?"ClassicGlass":"Standard");ProfileTheme.Apply(this,ProfileTheme.Dark);ApplyGlass();Navigate(ActivePage);}
    public void SetTheme(int mode){ProfileTheme.Apply(this,mode==2||(mode==0&&ProfileTheme.SystemDark()));ApplyGlass();Navigate(ActivePage);}
    public void SetMetricVisible(string key,bool visible){if(Metrics.ContainsKey(key)){Metrics[key].Tag=visible?null:"hidden";Metrics[key].Visible=visible;MetricHost.Reflow();}}
    static void Weekend(DataGridViewRow row,ProfileLedgerView value){DateTime date;if(value.Date.Contains("周")&&DateTime.TryParseExact(value.Key,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date)&&(date.DayOfWeek==DayOfWeek.Saturday||date.DayOfWeek==DayOfWeek.Sunday)){var a=ProfileTheme.Background;var b=ProfileTheme.Selection;row.DefaultCellStyle.BackColor=Color.FromArgb((a.R+b.R)/2,(a.G+b.G)/2,(a.B+b.B)/2);row.Cells[0].Style.ForeColor=ProfileTheme.Accent;}}
    static string CompactDuration(string value){return value==null?null:value.Replace(" ","");}
    public void SetLedger(ProfileLedgerView[] rows){string selected=Ledger.CurrentRow==null?"":Convert.ToString(Ledger.CurrentRow.Tag);Ledger.Rows.Clear();for(int c=1;c<=5;c++){Ledger.Columns[c].DefaultCellStyle.Alignment=DataGridViewContentAlignment.MiddleRight;Ledger.Columns[c].HeaderCell.Style.Alignment=DataGridViewContentAlignment.MiddleRight;}foreach(var r in rows){int i=Ledger.Rows.Add(r.Date,r.Energy,r.Cost,CompactDuration(r.Usage),CompactDuration(r.High),CompactDuration(r.Game),r.Source);Ledger.Rows[i].Tag=r.Key;Ledger.Columns[0].MinimumWidth=145;Ledger.Columns[0].DefaultCellStyle.WrapMode=DataGridViewTriState.True;if(r.PeriodEnd>r.PeriodStart)Ledger.Rows[i].Height=58;Ledger.Rows[i].Cells[0].ToolTipText=r.Explanation;if(r.Missing)Ledger.Rows[i].DefaultCellStyle.ForeColor=ProfileTheme.Muted;Weekend(Ledger.Rows[i],r);if(r.Key==selected)Ledger.CurrentCell=Ledger.Rows[i].Cells[0];}}
    public void SetGames(ProfileLedgerView[] rows){GameGrid.Rows.Clear();foreach(var r in rows){if(String.IsNullOrEmpty(r.Names))continue;int n=GameGrid.Rows.Add(r.Date,r.Names,r.Game,r.Estimated?"含日志会话推算":"游戏识别 / 采样");GameGrid.Rows[n].Tag=r.Key;Weekend(GameGrid.Rows[n],r);}}
    public void SelectLedger(string key){foreach(DataGridViewRow row in Ledger.Rows)if(Convert.ToString(row.Tag)==key){Ledger.CurrentCell=row.Cells[0];Ledger.FirstDisplayedScrollingRowIndex=row.Index;break;}}
    void PopulateDevice(ProfileSurface card,ProfileDeviceView d){var inherited=card.Font;if(DeferDevices&&textFactor!=1)card.Font=new Font("Microsoft YaHei UI",9);card.SuspendLayout();try{var title=Label((d.Favorite?"★ ":"")+d.Name,12,true);title.Dock=DockStyle.Top;title.Name="title";title.Height=36;title.AutoSize=false;title.AutoEllipsis=true;var body=Label(d.Status+"\n"+d.Room+"\n"+d.Details+"\n"+d.Next,9);body.Name="body";body.Dock=DockStyle.Fill;body.AutoSize=false;var actions=Row(Button("开启","DeviceOn",d.Id),Button("关闭","DeviceOff",d.Id),Button("定时","DeviceSchedule",d.Id));actions.Name="actions";actions.Dock=DockStyle.Bottom;actions.Height=36;foreach(Control b in actions.Controls)b.Enabled=d.CanControl;var manage=Row(Button(d.Favorite?"取消收藏":"收藏","Favorite",d.Id),Button("别名 / 分组","DeviceEdit",d.Id));manage.Name="manage";manage.Dock=DockStyle.Bottom;manage.Height=36;card.Controls.Add(body);card.Controls.Add(title);card.Controls.Add(actions);card.Controls.Add(manage);if(DeferDevices&&textFactor!=1){foreach(Control child in card.Controls){var fonts=new Dictionary<Control,Font>();CaptureFonts(child,fonts);child.Scale(new SizeF(textFactor,textFactor));foreach(var item in fonts)item.Key.Font=new Font(item.Value.FontFamily,item.Value.Size*textFactor,item.Value.Style);}card.Font=inherited;}ProfileTheme.Apply(card,ProfileTheme.Dark);}finally{card.ResumeLayout();}}
    public void SetDevices(ProfileDeviceView[] devices){
      if(deviceCards.Count==devices.Length&&devices.Length>0&&devices.All(d=>deviceCards.ContainsKey(d.Id))){foreach(var d in devices){var card=deviceCards[d.Id];card.Tag=d;if(card.Controls.Count==0)continue;card.Controls["title"].Text=(d.Favorite?"★ ":"")+d.Name;card.Controls["body"].Text=d.Status+"\n"+d.Room+"\n"+d.Details+"\n"+d.Next;foreach(Control button in card.Controls["actions"].Controls)button.Enabled=d.CanControl;card.Controls["manage"].Controls[0].Text=d.Favorite?"取消收藏":"收藏";}return;}
      DeviceHost.SuspendLayout();try{while(DeviceHost.Controls.Count>0)DeviceHost.Controls[0].Dispose();deviceCards.Clear();foreach(var d in devices){var card=new ProfileDeferredSurface{Height=212,Width=300,Tag=d};card.Populate=c=>PopulateDevice(c,(ProfileDeviceView)c.Tag);if(!DeferDevices)card.EnsureContent();DeviceHost.Controls.Add(card);deviceCards[d.Id]=card;}if(devices.Length==0)DeviceHost.Controls.Add(Label("没有匹配设备；先接入米家或调整搜索。",10));}finally{DeviceHost.ResumeLayout();DeviceHost.Reflow();}
    }
    protected override void OnFormClosing(FormClosingEventArgs e){if(e.CloseReason==CloseReason.UserClosing){e.Cancel=true;Hide();}base.OnFormClosing(e);}
    protected override void Dispose(bool disposing){if(disposing){SystemEvents.UserPreferenceChanged-=SystemThemeChanged;tips.Dispose();}base.Dispose(disposing);}
}
public sealed class ProfileConnectForm : Form {
    public event EventHandler<ProfileWorkspaceCommand> Command;
    public readonly TabControl Steps=new TabControl();public readonly TextBox Address=new TextBox(),Token=new TextBox();
    public readonly NumericUpDown Price=new NumericUpDown();public readonly Label Readiness=new Label(),ProbeStatus=new Label(),CloudStatus=new Label();
    public readonly Button Verify=new Button(),SaveConnection=new Button(),InstallCloud=new Button(),Login=new Button(),Sync=new Button();
    public ProfileConnectForm(){
        Text="PowerProfile · 连接与自检向导";Font=new Font("Microsoft YaHei UI",10);AutoScaleMode=AutoScaleMode.Dpi;ClientSize=new Size(700,590);MinimumSize=new Size(530,440);StartPosition=FormStartPosition.CenterParent;
        var head=new Label{Text="连接你的米家插座",Dock=DockStyle.Top,Height=64,Padding=new Padding(20,16,0,0),Font=new Font("Microsoft YaHei UI",18,FontStyle.Bold)};Controls.Add(Steps);Controls.Add(head);Steps.Dock=DockStyle.Fill;
        foreach(var name in new[]{"1 准备","2 连接信息","3 验证设备","4 电价与保存","5 云端可选"})Steps.TabPages.Add(new TabPage(name){Padding=new Padding(22),AutoScroll=true});
        Readiness.Dock=DockStyle.Fill;Readiness.AutoSize=false;Steps.TabPages[0].Controls.Add(Readiness);
        var inputs=new TableLayoutPanel{Dock=DockStyle.Top,AutoSize=true,ColumnCount=1};inputs.Controls.Add(ProfileWorkspaceForm.Label("插座局域网 IPv4"));Address.Dock=DockStyle.Top;Address.AccessibleName="插座 IPv4";inputs.Controls.Add(Address);inputs.Controls.Add(ProfileWorkspaceForm.Label("设备 Token（32 位十六进制；不是米家密码）"));Token.Dock=DockStyle.Top;Token.UseSystemPasswordChar=true;Token.AccessibleName="设备 Token";inputs.Controls.Add(Token);inputs.Controls.Add(ProfileWorkspaceForm.Label("电脑与插座需在同一局域网。\n已有授权时 Token 留空保留；授权不会回显或写入日志。\nIP 可从路由器设备列表查询，建议保留 DHCP 地址。",9));Steps.TabPages[1].Controls.Add(inputs);
        Verify.Text="开始只读验证";Verify.Dock=DockStyle.Top;Verify.Height=42;Verify.Click+=(s,e)=>Emit("Probe");ProbeStatus.Dock=DockStyle.Fill;ProbeStatus.Padding=new Padding(0,18,0,0);Steps.TabPages[2].Controls.Add(ProbeStatus);Steps.TabPages[2].Controls.Add(Verify);
        var billing=new TableLayoutPanel{Dock=DockStyle.Top,AutoSize=true,ColumnCount=1};billing.Controls.Add(ProfileWorkspaceForm.Label("固定电价 · 元 / 度"));Price.DecimalPlaces=3;Price.Minimum=0;Price.Maximum=10;Price.Increment=0.01M;Price.Width=180;billing.Controls.Add(Price);billing.Controls.Add(ProfileWorkspaceForm.Label("先验证设备，再保存。验证只读取，不切换插座。\n电价用于估算费用，实际结算以供电账单为准。",9));SaveConnection.Text="保存并开始监测";SaveConnection.AutoSize=true;SaveConnection.Height=42;SaveConnection.Enabled=false;SaveConnection.Click+=(s,e)=>Emit("Save");billing.Controls.Add(SaveConnection);Steps.TabPages[3].Controls.Add(billing);
        var cloud=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown,WrapContents=false,AutoScroll=true};CloudStatus.AutoSize=true;CloudStatus.MaximumSize=new Size(580,0);cloud.Controls.Add(CloudStatus);foreach(var entry in new[]{Tuple.Create(InstallCloud,"安装云端连接组件","Install"),Tuple.Create(Login,"米家 App 扫码授权","Login"),Tuple.Create(Sync,"同步设备并检查授权","Sync")}){var b=entry.Item1;b.Text=entry.Item2;b.AutoSize=true;b.MinimumSize=new Size(240,40);b.Margin=new Padding(0,7,0,7);string action=entry.Item3;b.Click+=(s,e)=>Emit(action);cloud.Controls.Add(b);}cloud.Controls.Add(ProfileWorkspaceForm.Label("云端可选：本地功率监测无需安装。\n设备中枢、定时任务和云端历史需要该组件与扫码授权。\n仅发现可写开关才允许控制，不把授权文件存在当作连接成功。",9));Steps.TabPages[4].Controls.Add(cloud);
        var footer=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=56,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(12)};var next=new Button{Text="下一步",AutoSize=true,Height=34};var back=new Button{Text="上一步",AutoSize=true,Height=34};next.Click+=(s,e)=>{if(Steps.SelectedIndex<4)Steps.SelectedIndex++;else Close();};back.Click+=(s,e)=>{if(Steps.SelectedIndex>0)Steps.SelectedIndex--;};Steps.SelectedIndexChanged+=(s,e)=>{back.Enabled=Steps.SelectedIndex>0;next.Text=Steps.SelectedIndex==4?"完成":"下一步";};footer.Controls.Add(next);footer.Controls.Add(back);Controls.Add(footer);head.SendToBack();footer.SendToBack();Steps.BringToFront();Address.TextChanged+=(s,e)=>Emit("InputChanged");Token.TextChanged+=(s,e)=>Emit("InputChanged");
    }
    void Emit(string action){if(Command!=null)Command(this,new ProfileWorkspaceCommand(action,""));}
    protected override void Dispose(bool disposing){if(disposing)Token.Clear();base.Dispose(disposing);}
}
