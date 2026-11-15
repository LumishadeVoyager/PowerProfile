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
    public static Color Background {get{return SystemInformation.HighContrast?SystemColors.Window:Dark?Color.FromArgb(24,27,33):Color.FromArgb(245,247,250);}}
    public static Color Surface {get{return SystemInformation.HighContrast?SystemColors.Window:Dark?Color.FromArgb(34,39,47):Color.White;}}
    public static Color Text {get{return SystemInformation.HighContrast?SystemColors.WindowText:Dark?Color.FromArgb(233,237,242):Color.FromArgb(33,44,60);}}
    public static Color Muted {get{return Dark?Color.FromArgb(166,178,194):Color.FromArgb(96,112,131);}}
    public static Color Border {get{return Dark?Color.FromArgb(60,69,83):Color.FromArgb(221,228,237);}}
    public static Color Accent {get{return Dark?Color.FromArgb(115,182,248):Color.FromArgb(32,104,184);}}
    public static Color Selection {get{return Dark?Color.FromArgb(42,65,87):Color.FromArgb(228,239,252);}}
    public static bool SystemDark(){try{return Convert.ToInt32(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize","AppsUseLightTheme",1))==0;}catch{return false;}}
    public static void Apply(Control root,bool dark){Dark=dark;Paint(root);root.Invalidate(true);}
    static void Paint(Control c){
        bool surface=c is ProfileSurface || c is TextBoxBase || c is ComboBox || c is NumericUpDown || c is DataGridView;
        c.BackColor=surface?Surface:(c is Form||c.Parent==null?Background:c.Parent.BackColor);c.ForeColor=Text;
        if(c is Label && (c.Tag as string)=="muted")c.ForeColor=Muted;
        var b=c as Button;if(b!=null){b.FlatStyle=FlatStyle.Flat;b.FlatAppearance.BorderColor=Border;b.BackColor=Surface;b.ForeColor=Text;b.Padding=new Padding(8,3,8,3);}
        var g=c as DataGridView;if(g!=null){g.BackgroundColor=Surface;g.GridColor=Border;g.DefaultCellStyle.BackColor=Surface;g.DefaultCellStyle.ForeColor=Text;g.DefaultCellStyle.SelectionBackColor=Selection;g.DefaultCellStyle.SelectionForeColor=Text;g.AlternatingRowsDefaultCellStyle.BackColor=Background;g.ColumnHeadersDefaultCellStyle.BackColor=Background;g.ColumnHeadersDefaultCellStyle.ForeColor=Muted;}
        var link=c as LinkLabel;if(link!=null)link.LinkColor=Accent;
        foreach(Control child in c.Controls)Paint(child);
        if(c is ProfileSurface)c.Invalidate();
    }
}
public class ProfileSurface : Panel {
    public ProfileSurface(){DoubleBuffered=true;Font=new Font("Microsoft YaHei UI",9F);Padding=new Padding(18);Margin=new Padding(0,0,14,14);BackColor=ProfileTheme.Surface;}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);using(var p=new Pen(ProfileTheme.Border))e.Graphics.DrawRectangle(p,0,0,Width-1,Height-1);}
}
public sealed class ProfileWrap : FlowLayoutPanel {
    public int ItemWidth=260;bool reflow;
    public ProfileWrap(){AutoSize=false;WrapContents=true;Dock=DockStyle.Top;Margin=Padding.Empty;}
    protected override void OnSizeChanged(EventArgs e){base.OnSizeChanged(e);Reflow();}
    protected override void OnControlAdded(ControlEventArgs e){base.OnControlAdded(e);Reflow();}
    public void Reflow(){if(reflow||ClientSize.Width<1)return;reflow=true;try{int columns=Math.Max(1,Math.Min(4,ClientSize.Width/(ItemWidth+14)));int width=Math.Max(100,ClientSize.Width/columns-14);var items=Controls.Cast<Control>().Where(c=>(c.Tag as string)!="hidden").ToArray();foreach(var c in items)c.Width=width;int height=items.Length==0?1:(int)Math.Ceiling(items.Length/(double)columns)*(items.Max(c=>c.Height+c.Margin.Vertical));if(Height!=height)Height=height;}finally{reflow=false;}}
}
public sealed class ProfileRow : FlowLayoutPanel {
    bool sizing;
    public ProfileRow(){AutoSize=false;WrapContents=true;Dock=DockStyle.Top;Height=46;Margin=new Padding(0,3,0,10);}
    protected override void OnLayout(LayoutEventArgs e){base.OnLayout(e);if(sizing)return;sizing=true;try{int bottom=Controls.Count==0?1:Controls.Cast<Control>().Max(c=>c.Bottom+c.Margin.Bottom)+Padding.Bottom;if(Height!=bottom)Height=bottom;}finally{sizing=false;}}
}
public sealed class ProfileMetric : ProfileSurface {
    public readonly Label Caption=new Label(),Value=new Label(),Context=new Label();
    public ProfileMetric(string title){Height=138;Caption.Text=title;Caption.Dock=DockStyle.Top;Caption.Height=26;Caption.Tag="muted";Value.Dock=DockStyle.Top;Value.Height=47;Value.Font=new Font("Microsoft YaHei UI",22,FontStyle.Bold);Context.Dock=DockStyle.Fill;Context.Tag="muted";Controls.Add(Context);Controls.Add(Value);Controls.Add(Caption);Value.Text="—";}
    public void Set(string value,string context){Value.Text=value;Context.Text=context;Value.ForeColor=ProfileTheme.Accent;}
}
public sealed class ProfileScheduleCanvas : Control {
    public List<ProfileScheduleSlot> Slots=new List<ProfileScheduleSlot>();public DateTime WeekStart=DateTime.Today;
    readonly ToolTip tip=new ToolTip();readonly List<Tuple<RectangleF,ProfileScheduleSlot>> hit=new List<Tuple<RectangleF,ProfileScheduleSlot>>();
    public event EventHandler<ProfileWorkspaceCommand> Selected;
    public ProfileScheduleCanvas(){DoubleBuffered=true;Height=470;Dock=DockStyle.Top;AccessibleName="七日设备任务时间轴";SetStyle(ControlStyles.Selectable,true);TabStop=true;}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(ProfileTheme.Surface);hit.Clear();float left=106,w=Math.Max(1,Width-left-16),row=Math.Max(53,(Height-38)/7f);
        using(var text=new SolidBrush(ProfileTheme.Muted))using(var line=new Pen(ProfileTheme.Border)){
            for(int h=0;h<=24;h+=4){float x=left+w*h/24;g.DrawString(h.ToString("00")+":00",Font,text,x-16,3);g.DrawLine(line,x,27,x,Height-4);}
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
    protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);var item=hit.FirstOrDefault(x=>x.Item1.Contains(e.Location));tip.SetToolTip(this,item==null?"":item.Item2.Device+" · "+item.Item2.Name+"\n"+item.Item2.Start.ToString("MM-dd ddd HH:mm")+" — "+item.Item2.End.ToString("MM-dd ddd HH:mm")+"\n"+item.Item2.Status);}
    protected override void OnMouseClick(MouseEventArgs e){base.OnMouseClick(e);var item=hit.FirstOrDefault(x=>x.Item1.Contains(e.Location));if(item!=null&&Selected!=null)Selected(this,new ProfileWorkspaceCommand("SelectRule",item.Item2.Id));}
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
}
public sealed class ProfileWorkspaceForm : Form {
    public event EventHandler<ProfileWorkspaceCommand> Command;
    public readonly Dictionary<string,Panel> Pages=new Dictionary<string,Panel>();
    public readonly Dictionary<string,ProfileMetric> Metrics=new Dictionary<string,ProfileMetric>();
    public readonly Dictionary<string,Button> Navigation=new Dictionary<string,Button>();
    public readonly Label Footer=new Label(),OverviewReason=new Label(),Runtime=new Label(),Quality=new Label(),SelectionInfo=new Label(),TaskInfo=new Label(),GameInfo=new Label();
    public readonly Panel ChartHost=new Panel();public readonly ProfileScheduleCanvas Calendar=new ProfileScheduleCanvas();
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
    public string ActivePage="Overview";public int WeekOffset;bool building=true;readonly Panel sidebar=new Panel(),content=new Panel();readonly Label heading=new Label(),subheading=new Label();
    readonly Dictionary<string,ProfileSurface> deviceCards=new Dictionary<string,ProfileSurface>();readonly Label brand;readonly float textFactor;
    public ProfileWorkspaceForm():this(100){}
    public ProfileWorkspaceForm(int textScale){
        textFactor=textScale==125?1.25f:textScale==150?1.5f:1f;
        Text="PowerProfile";Font=new Font("Microsoft YaHei UI",9F);AutoScaleMode=AutoScaleMode.Dpi;ClientSize=new Size(1240,900);MinimumSize=new Size(700,620);StartPosition=FormStartPosition.CenterScreen;KeyPreview=true;
        sidebar.Dock=DockStyle.Left;sidebar.Width=190;sidebar.Padding=new Padding(14,20,14,14);Controls.Add(content);Controls.Add(sidebar);content.Dock=DockStyle.Fill;content.Padding=new Padding(24,16,14,0);
        brand=Label("PowerProfile",18,true);brand.Dock=DockStyle.Top;brand.Height=55;sidebar.Controls.Add(brand);
        string[][] destinations={new[]{"Overview","总览"},new[]{"Energy","用电分析"},new[]{"Games","游戏记录"},new[]{"Devices","设备"},new[]{"Automation","自动化"},new[]{"Settings","设置"}};
        var nav=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown,WrapContents=false};sidebar.Controls.Add(nav);nav.BringToFront();brand.BringToFront();
        int iconIndex=0;string[] icons={"◉","▥","▷","▦","◷","⚙"};foreach(var entry in destinations){var key=entry[0];var b=Button(icons[iconIndex++]+"  "+entry[1],"Navigate",key);b.AccessibleName=entry[1];b.AutoSize=false;b.Size=new Size(158,46);b.Margin=new Padding(0,3,0,3);b.TextAlign=ContentAlignment.MiddleLeft;nav.Controls.Add(b);Navigation[key]=b;var page=new Panel{Dock=DockStyle.Fill,AutoScroll=true,Padding=new Padding(0,10,10,12),Visible=false};Pages[key]=page;content.Controls.Add(page);}
        var header=new Panel{Dock=DockStyle.Top,Height=82};heading=Label("总览",22,true);heading.Dock=DockStyle.Top;heading.Height=44;subheading.Text="电源、用电与设备，一处掌握";subheading.Dock=DockStyle.Top;subheading.Height=29;subheading.Tag="muted";header.Controls.Add(subheading);header.Controls.Add(heading);content.Controls.Add(header);header.BringToFront();
        Footer.Dock=DockStyle.Bottom;Footer.Height=44;Footer.Padding=new Padding(8);Footer.Tag="muted";Footer.Text="准备读取本机状态…";content.Controls.Add(Footer);Footer.BringToFront();
        // Overview
        var home=Column(Pages["Overview"]);home.Controls.Add(Row(Button("自动切换","Auto"),Button("静音","Idle"),Button("均衡","Balanced"),Button("游戏","Game"),Button("选择总览卡片","Navigate","Settings")));
        foreach(var entry in new[]{new[]{"mode","当前电源档位"},new[]{"power","实时输入功率"},new[]{"cost","今日电费"},new[]{"usage","今日电脑使用"},new[]{"game","今日游戏时长"},new[]{"next","下一项自动化"}}){var card=new ProfileMetric(entry[1]);Metrics[entry[0]]=card;MetricHost.Controls.Add(card);}home.Controls.Add(MetricHost);
        AddText(home,"运行与连接",13,true);OverviewReason.AutoSize=true;OverviewReason.MaximumSize=new Size(1000,0);home.Controls.Add(OverviewReason);Runtime.AutoSize=true;Runtime.MaximumSize=new Size(1000,0);Runtime.Tag="muted";home.Controls.Add(Runtime);home.Controls.Add(Row(Button("连接自检向导","Connection"),Button("硬件监测","Hardware"),Button("查看日志","Logs"),Button("设备与任务","Navigate","Automation")));
        // Energy
        var energy=Column(Pages["Energy"]);Range=Combo(new[]{"近 7 天","近 30 天","近 90 天"});Range.SelectedIndex=1;Group=Combo(new[]{"按日","按周","按月"});Group.SelectedIndex=0;energy.Controls.Add(Row(new Label{Text="查看范围",AutoSize=true},Range,Group,Button("连接与电价","Connection"),Button("补录米家历史","Cloud"),Button("刷新","RefreshEnergy")));
        var series=Row();string[] seriesNames={"电费 · 蓝","使用 · 绿","高功耗 · 橙","游戏 · 紫"};for(int i=0;i<4;i++){int n=i;var check=new CheckBox{Text=seriesNames[i],Checked=true,AutoSize=true,Margin=new Padding(0,8,18,6)};check.CheckedChanged+=(s,e)=>Emit("Series",n+":"+check.Checked);series.Controls.Add(check);}series.Controls.Add(Button("恢复全时段","ResetChart"));energy.Controls.Add(series);
        ChartHost.Height=290;ChartHost.Margin=new Padding(0,4,0,10);energy.Controls.Add(ChartHost);AddText(energy,"滚轮缩放 · 拖动选择区间 · 点击数据点联动明细",9,false);
        Quality.AutoSize=true;Quality.MaximumSize=new Size(1100,0);Quality.Tag="muted";energy.Controls.Add(Quality);
        LedgerSearch.Width=210;LedgerSearch.AccessibleName="搜索日期、游戏或来源";DayFilter=Combo(new[]{"全部日期","周一至周五","周六与周日"});SourceFilter=Combo(new[]{"全部来源","米家历史","本机功率积分","无电量记录"});QualityFilter=Combo(new[]{"全部记录","含会话推算","缺少电量"});
        energy.Controls.Add(Row(new Label{Text="搜索明细",AutoSize=true},LedgerSearch,DayFilter,SourceFilter,QualityFilter));
        foreach(var picker in new[]{FromDate,ToDate}){picker.Format=DateTimePickerFormat.Custom;picker.CustomFormat="yyyy-MM-dd dddd";picker.Width=200;picker.Value=DateTime.Today;picker.Enabled=false;}FromDate.Value=DateTime.Today.AddDays(-29);
        energy.Controls.Add(Row(CustomDates,FromDate,new Label{Text="至",AutoSize=true},ToDate,Button("显示列","LedgerColumns")));
        energy.Controls.Add(Row(Button("导出当前明细 CSV","ExportCsv"),Button("导出当前图表 PNG","ExportPng"),Button("导出所选月份报告","ExportReport")));
        Ledger=Grid(new[]{"日期 / 星期","电量 kWh","电费","使用时长","高功耗","游戏","电量来源"});Ledger.Height=300;energy.Controls.Add(Ledger);SelectionInfo.AutoSize=true;SelectionInfo.MaximumSize=new Size(1100,0);energy.Controls.Add(SelectionInfo);Ledger.SelectionChanged+=(s,e)=>Emit("LedgerSelection",Ledger.CurrentRow==null?"":Convert.ToString(Ledger.CurrentRow.Tag));
        foreach(DataGridViewColumn c in Ledger.Columns)c.SortMode=DataGridViewColumnSortMode.Programmatic;Ledger.ColumnHeaderMouseClick+=(s,e)=>Emit("LedgerSort",e.ColumnIndex.ToString());
        LedgerSearch.TextChanged+=(s,e)=>Emit("InsightsFilter");DayFilter.SelectedIndex=0;SourceFilter.SelectedIndex=0;QualityFilter.SelectedIndex=0;
        foreach(var combo in new[]{DayFilter,SourceFilter,QualityFilter})combo.SelectedIndexChanged+=(s,e)=>Emit("InsightsFilter");
        CustomDates.CheckedChanged+=(s,e)=>{FromDate.Enabled=ToDate.Enabled=CustomDates.Checked;Emit("InsightsFilter");};FromDate.ValueChanged+=(s,e)=>Emit("InsightsFilter");ToDate.ValueChanged+=(s,e)=>Emit("InsightsFilter");
        energy.Controls.Add(Insights);Insights.Metric.SelectedIndexChanged+=(s,e)=>Emit("InsightsFilter");Insights.Heatmap.Selected+=(s,e)=>Emit(e.Action,e.Id);
        Range.SelectedIndexChanged+=(s,e)=>Emit("EnergyRange");Group.SelectedIndexChanged+=(s,e)=>Emit("EnergyRange");
        // Games: evidence-backed existing day records, no process monitoring policy changes.
        var games=Column(Pages["Games"]);AddText(games,"独立游戏分析",15,true);GameInfo.AutoSize=true;GameInfo.MaximumSize=new Size(1100,0);games.Controls.Add(GameInfo);
        GameRange=Combo(new[]{"近 7 天","近 30 天","近 90 天","近 400 天"});GameRange.SelectedIndex=1;GameSearch.Width=230;GameSearch.AccessibleName="搜索游戏名称";games.Controls.Add(Row(GameRange,new Label{Text="搜索游戏",AutoSize=true},GameSearch,Button("全部游戏","GamesFilter"),Button("导出游戏明细 CSV","ExportGames")));
        GameTotals=Grid(new[]{"游戏名称","记录时长","片段数","功率覆盖","采样均功率 W","采样电费"});GameTotals.Height=240;GameTotals.Columns[0].MinimumWidth=210;GameTotals.Columns[0].FillWeight=170;GameTotals.Columns[0].DefaultCellStyle.WrapMode=DataGridViewTriState.True;GameTotals.RowTemplate.Height=48;games.Controls.Add(GameTotals);
        AddText(games,"会话片段 · 点击查看证据",13,true);GameSessions=Grid(new[]{"游戏名称","开始 / 星期","结束 / 星期","时长","功率覆盖","采样均功率 W","采样电费","依据"});GameSessions.Height=320;int[] widths={160,145,145,100,125,105,100,150};for(int c=0;c<widths.Length;c++){GameSessions.Columns[c].MinimumWidth=widths[c];GameSessions.Columns[c].DefaultCellStyle.WrapMode=DataGridViewTriState.True;}GameSessions.RowTemplate.Height=58;games.Controls.Add(GameSessions);GameDetail.AutoSize=true;GameDetail.MaximumSize=new Size(1100,0);games.Controls.Add(GameDetail);
        GameTotals.SelectionChanged+=(s,e)=>Emit("GameSelect",GameTotals.CurrentRow==null?"":Convert.ToString(GameTotals.CurrentRow.Tag));GameSessions.SelectionChanged+=(s,e)=>Emit("GameSessionSelect",GameSessions.CurrentRow==null?"":Convert.ToString(GameSessions.CurrentRow.Tag));GameRange.SelectedIndexChanged+=(s,e)=>Emit("GamesFilter");GameSearch.TextChanged+=(s,e)=>Emit("GamesFilter");
        AddText(games,"逐日汇总 · 多个游戏名称不代表可逐一分摊时长",13,true);GameGrid=Grid(new[]{"日期 / 星期","游戏名称","游戏时长","覆盖 / 依据"});GameGrid.Height=230;games.Controls.Add(GameGrid);AddText(games,"切档会话为推算；插座功率包含整机与充电。费用仅计算实际采样覆盖，不外推缺失时段。",9,false);
        // Devices
        var devices=Column(Pages["Devices"]);Search.Width=210;Search.AccessibleName="搜索设备名称或型号";Room=Combo(new[]{"全部分组"});Room.SelectedIndex=0;Favorites.Text="仅收藏";Favorites.AutoSize=true;devices.Controls.Add(Row(new Label{Text="查找设备",AutoSize=true},Search,Room,Favorites,Button("同步设备","RefreshDevices"),Button("接入向导","Connection")));
        DeviceHost.ItemWidth=280;DeviceHost.ControlAdded+=(s,e)=>{if(textFactor!=1&&e.Control is ProfileSurface){var fonts=new Dictionary<Control,Font>();CaptureFonts(e.Control,fonts);e.Control.Scale(new SizeF(textFactor,textFactor));foreach(var item in fonts)item.Key.Font=new Font(item.Value.FontFamily,item.Value.Size*textFactor,item.Value.Style);DeviceHost.Reflow();}};devices.Controls.Add(DeviceHost);Search.TextChanged+=(s,e)=>Emit("FilterDevices");Room.SelectedIndexChanged+=(s,e)=>Emit("FilterDevices");Favorites.CheckedChanged+=(s,e)=>Emit("FilterDevices");
        // Automation
        var automation=Column(Pages["Automation"]);CalendarDevice=Combo(new[]{"全部设备"});CalendarDevice.SelectedIndex=0;
        automation.Controls.Add(Row(Button("上一周","Week","-1"),Button("本周","Week","0"),Button("下一周","Week","1"),CalendarDevice,Button("启动 / 暂停中枢","ToggleHub"),Button("添加任务","NewRule")));
        TaskInfo.AutoSize=true;TaskInfo.MaximumSize=new Size(1100,0);automation.Controls.Add(TaskInfo);automation.Controls.Add(Calendar);Calendar.Selected+=(s,e)=>Emit(e.Action,e.Id);CalendarDevice.SelectedIndexChanged+=(s,e)=>Emit("CalendarFilter");RuleGrid=Grid(new[]{"任务","设备","执行安排","下次 / 状态"});RuleGrid.Height=225;automation.Controls.Add(RuleGrid);automation.Controls.Add(Row(Button("编辑所选","EditRule"),Button("启用 / 暂停所选","ToggleRule"),Button("移除所选","RemoveRule")));
        AddText(automation,"本机执行：需要电脑唤醒、联网；关闭窗口仍保留后台任务。",9,false);
        // Settings
        var settings=Column(Pages["Settings"]);AddText(settings,"外观",15,true);Theme=Combo(new[]{"跟随系统","浅色","深色"});Theme.SelectedIndex=0;TextSize=Combo(new[]{"标准 100%","较大 125%","大号 150%"});TextSize.SelectedIndex=textScale==150?2:textScale==125?1:0;settings.Controls.Add(Row(new Label{Text="应用主题",AutoSize=true},Theme,new Label{Text="文字与控件",AutoSize=true},TextSize));Theme.SelectedIndexChanged+=(s,e)=>Emit("Theme",Theme.SelectedIndex.ToString());TextSize.SelectedIndexChanged+=(s,e)=>Emit("TextSize",new[]{100,125,150}[TextSize.SelectedIndex].ToString());AddText(settings,"总览卡片",13,true);var options=Row();foreach(var entry in Metrics){string key=entry.Key;var check=new CheckBox{Text=entry.Value.Caption.Text,Checked=true,AutoSize=true,Margin=new Padding(0,8,18,8)};check.CheckedChanged+=(s,e)=>Emit("Metric",key+":"+check.Checked);MetricOptions[key]=check;options.Controls.Add(check);}settings.Controls.Add(options);
        AddText(settings,"电源与保护",13,true);settings.Controls.Add(Row(Button("档位与识别参数","AdvancedSettings"),Button("省电计划与常用设置","PlanSettings"),Button("C-state 稳定性保护","CState")));
        AddText(settings,"连接与维护",13,true);settings.Controls.Add(Row(Button("分步接入与自检","Connection"),Button("使用手册与更新","Welcome"),Button("运行日志","Logs")));
        AddText(settings,"后台状态和窗口关闭",13,true);AddText(settings,"关闭此窗口只隐藏工作台。托盘与已启用的自动化中枢继续运行。\n停止设备自动化请使用自动化页的暂停中枢；原有托盘退出行为保持。",10,false);
        SizeChanged+=(s,e)=>Adapt();KeyDown+=(s,e)=>{if(e.Control&&e.KeyCode==Keys.D1)Navigate("Overview");if(e.Control&&e.KeyCode==Keys.D2)Navigate("Energy");if(e.Control&&e.KeyCode==Keys.D3)Navigate("Devices");if(e.Control&&e.KeyCode==Keys.D4)Navigate("Automation");if(e.KeyCode==Keys.F5)Emit("Refresh");};
        brand.SendToBack();nav.BringToFront();header.SendToBack();Footer.SendToBack();
        if(textScale==125||textScale==150){float factor=textScale/100f;var fonts=new Dictionary<Control,Font>();CaptureFonts(this,fonts);Scale(new SizeF(factor,factor));foreach(var item in fonts)item.Key.Font=new Font(item.Value.FontFamily,item.Value.Size*factor,item.Value.Style);MetricHost.ItemWidth=(int)(260*factor);DeviceHost.ItemWidth=(int)(280*factor);}
        SystemEvents.UserPreferenceChanged+=SystemThemeChanged;building=false;Navigate("Overview");Adapt();
    }
    static void CaptureFonts(Control c,Dictionary<Control,Font> fonts){fonts[c]=c.Font;foreach(Control child in c.Controls)CaptureFonts(child,fonts);}
    public static void ScaleDialog(Form form,int percent){if(percent!=125&&percent!=150)return;float factor=percent/100f;var fonts=new Dictionary<Control,Font>();CaptureFonts(form,fonts);form.Scale(new SizeF(factor,factor));foreach(var item in fonts)item.Key.Font=new Font(item.Value.FontFamily,item.Value.Size*factor,item.Value.Style);form.AutoScroll=true;form.AutoScrollMinSize=form.ClientSize;var area=Screen.FromControl(form).WorkingArea;form.Size=new Size(Math.Min(form.Width,area.Width-30),Math.Min(form.Height,area.Height-40));}
    void SystemThemeChanged(object sender,UserPreferenceChangedEventArgs e){if(IsDisposed)return;try{BeginInvoke((Action)(()=>{if(Theme.SelectedIndex==0)SetTheme(0);}));}catch{}}
    public void Emit(string action,string id=""){if(!building&&Command!=null)Command(this,new ProfileWorkspaceCommand(action,id));}
    public static Label Label(string text,float size=10,bool bold=false){return new Label{Text=text,AutoSize=true,Font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular),Margin=new Padding(0,10,0,10)};}
    Button Button(string text,string action,string id=""){var b=new Button{Text=text,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,MinimumSize=new Size(0,34),Margin=new Padding(0,3,10,6)};b.Click+=(s,e)=>Emit(action,id);return b;}
    public static ComboBox Combo(string[] choices){var c=new ComboBox{DropDownStyle=ComboBoxStyle.DropDownList,Width=145,Margin=new Padding(0,4,12,7)};c.Items.AddRange(choices);return c;}
    static FlowLayoutPanel Row(params Control[] controls){var row=new ProfileRow();foreach(var c in controls)row.Controls.Add(c);return row;}
    static FlowLayoutPanel Column(Panel parent){var col=new FlowLayoutPanel{FlowDirection=FlowDirection.TopDown,WrapContents=false,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,Location=new Point(0,0),Width=parent.ClientSize.Width};col.ControlAdded+=(s,e)=>{e.Control.Dock=DockStyle.None;e.Control.Anchor=AnchorStyles.Top|AnchorStyles.Left;e.Control.Width=Math.Max(100,col.Width-8);};parent.Controls.Add(col);parent.SizeChanged+=(s,e)=>{int width=Math.Max(100,parent.ClientSize.Width-22);col.MinimumSize=Size.Empty;col.MaximumSize=new Size(width,0);col.MinimumSize=new Size(width,0);col.Width=width;foreach(Control c in col.Controls){c.Width=width-8;var f=c as ProfileWrap;if(f!=null)f.Reflow();if(c is Label)((Label)c).MaximumSize=new Size(width-8,0);}};return col;}
    static void AddText(FlowLayoutPanel parent,string text,float size,bool bold){var l=Label(text,size,bold);l.MaximumSize=new Size(1100,0);if(!bold)l.Tag="muted";parent.Controls.Add(l);}
    public static DataGridView Grid(string[] columns){var grid=new DataGridView{ReadOnly=true,AllowUserToAddRows=false,AllowUserToDeleteRows=false,AllowUserToResizeRows=false,RowHeadersVisible=false,MultiSelect=false,SelectionMode=DataGridViewSelectionMode.FullRowSelect,AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill,BorderStyle=BorderStyle.None,EnableHeadersVisualStyles=false,ColumnHeadersHeight=36};grid.RowTemplate.Height=37;foreach(var name in columns){int i=grid.Columns.Add("c"+grid.Columns.Count,name);grid.Columns[i].MinimumWidth=75;}grid.ClipboardCopyMode=DataGridViewClipboardCopyMode.EnableAlwaysIncludeHeaderText;return grid;}
    public void Navigate(string key){if(!Pages.ContainsKey(key))return;ActivePage=key;foreach(var entry in Pages)entry.Value.Visible=entry.Key==key;Pages[key].BringToFront();heading.Text=Navigation[key].AccessibleName;subheading.Text=key=="Energy"?"费用与时长分轴显示 · 日期均为北京时间":key=="Automation"?"下次执行时间与七日安排 · 本机运行":key=="Devices"?"设备状态需读回确认 · 常用设备可分组收藏":"电源、用电与设备，一处掌握";foreach(var entry in Navigation){entry.Value.BackColor=entry.Key==key?ProfileTheme.Selection:ProfileTheme.Background;entry.Value.ForeColor=entry.Key==key?ProfileTheme.Accent:ProfileTheme.Text;}Adapt();Emit("Page",key);}
    void Adapt(){sidebar.Width=(int)((ClientSize.Width<940*textFactor?130:190)*textFactor);if(brand!=null)brand.Text=sidebar.Width<150*textFactor?"PP":"PowerProfile";foreach(var b in Navigation.Values)b.Width=sidebar.Width-28;foreach(var p in Pages.Values){var col=p.Controls.OfType<FlowLayoutPanel>().FirstOrDefault();if(col!=null){int width=Math.Max(100,p.ClientSize.Width-22);col.MinimumSize=Size.Empty;col.MaximumSize=new Size(width,0);col.MinimumSize=new Size(width,0);col.Width=width;foreach(Control c in col.Controls){c.Dock=DockStyle.None;c.Width=width-8;if(c is Label)((Label)c).MaximumSize=new Size(width-8,0);}col.PerformLayout();}}MetricHost.Reflow();DeviceHost.Reflow();Calendar.Invalidate();}
    public void SetTheme(int mode){ProfileTheme.Apply(this,mode==2||(mode==0&&ProfileTheme.SystemDark()));Navigate(ActivePage);}
    public void SetMetricVisible(string key,bool visible){if(Metrics.ContainsKey(key)){Metrics[key].Tag=visible?null:"hidden";Metrics[key].Visible=visible;MetricHost.Reflow();}}
    static void Weekend(DataGridViewRow row,ProfileLedgerView value){DateTime date;if(value.Date.Contains("周")&&DateTime.TryParseExact(value.Key,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date)&&(date.DayOfWeek==DayOfWeek.Saturday||date.DayOfWeek==DayOfWeek.Sunday)){var a=ProfileTheme.Background;var b=ProfileTheme.Selection;row.DefaultCellStyle.BackColor=Color.FromArgb((a.R+b.R)/2,(a.G+b.G)/2,(a.B+b.B)/2);row.Cells[0].Style.ForeColor=ProfileTheme.Accent;}}
    public void SetLedger(ProfileLedgerView[] rows){string selected=Ledger.CurrentRow==null?"":Convert.ToString(Ledger.CurrentRow.Tag);Ledger.Rows.Clear();for(int c=1;c<=5;c++){Ledger.Columns[c].DefaultCellStyle.Alignment=DataGridViewContentAlignment.MiddleRight;Ledger.Columns[c].HeaderCell.Style.Alignment=DataGridViewContentAlignment.MiddleRight;}foreach(var r in rows){int i=Ledger.Rows.Add(r.Date,r.Energy,r.Cost,r.Usage,r.High,r.Game,r.Source);Ledger.Rows[i].Tag=r.Key;Ledger.Columns[0].MinimumWidth=145;Ledger.Columns[0].DefaultCellStyle.WrapMode=DataGridViewTriState.True;if(r.PeriodEnd>r.PeriodStart)Ledger.Rows[i].Height=58;Ledger.Rows[i].Cells[0].ToolTipText=r.Explanation;if(r.Missing)Ledger.Rows[i].DefaultCellStyle.ForeColor=ProfileTheme.Muted;Weekend(Ledger.Rows[i],r);if(r.Key==selected)Ledger.CurrentCell=Ledger.Rows[i].Cells[0];}}
    public void SetGames(ProfileLedgerView[] rows){GameGrid.Rows.Clear();foreach(var r in rows){if(String.IsNullOrEmpty(r.Names))continue;int n=GameGrid.Rows.Add(r.Date,r.Names,r.Game,r.Estimated?"含日志会话推算":"游戏识别 / 采样");GameGrid.Rows[n].Tag=r.Key;Weekend(GameGrid.Rows[n],r);}}
    public void SelectLedger(string key){foreach(DataGridViewRow row in Ledger.Rows)if(Convert.ToString(row.Tag)==key){Ledger.CurrentCell=row.Cells[0];Ledger.FirstDisplayedScrollingRowIndex=row.Index;break;}}
    public void SetDevices(ProfileDeviceView[] devices){DeviceHost.SuspendLayout();while(DeviceHost.Controls.Count>0)DeviceHost.Controls[0].Dispose();deviceCards.Clear();foreach(var d in devices){var card=new ProfileSurface{Height=274,Width=300};var title=Label((d.Favorite?"★ ":"")+d.Name,12,true);title.Dock=DockStyle.Top;title.Height=42;title.AutoSize=false;var body=Label(d.Status+"\n"+d.Room+" · "+d.Model+"\n"+d.Details+"\n"+d.Next,9);body.Dock=DockStyle.Fill;body.AutoSize=false;var actions=Row(Button("开启","DeviceOn",d.Id),Button("关闭","DeviceOff",d.Id),Button("定时","DeviceSchedule",d.Id));actions.Dock=DockStyle.Bottom;actions.Height=43;foreach(Control b in actions.Controls)b.Enabled=d.CanControl;var manage=Row(Button(d.Favorite?"取消收藏":"收藏","Favorite",d.Id),Button("别名 / 分组","DeviceEdit",d.Id));manage.Dock=DockStyle.Bottom;manage.Height=43;card.Controls.Add(body);card.Controls.Add(title);card.Controls.Add(actions);card.Controls.Add(manage);DeviceHost.Controls.Add(card);deviceCards[d.Id]=card;}if(devices.Length==0)DeviceHost.Controls.Add(Label("没有匹配设备；先接入米家或调整分组与搜索。",10));DeviceHost.ResumeLayout();DeviceHost.Reflow();ProfileTheme.Apply(DeviceHost,ProfileTheme.Dark);}
    protected override void OnFormClosing(FormClosingEventArgs e){if(e.CloseReason==CloseReason.UserClosing){e.Cancel=true;Hide();}base.OnFormClosing(e);}
    protected override void Dispose(bool disposing){if(disposing)SystemEvents.UserPreferenceChanged-=SystemThemeChanged;base.Dispose(disposing);}
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
