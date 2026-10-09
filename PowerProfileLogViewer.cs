using System;
using System.IO;
using System.Text;
using System.Drawing;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public sealed class ProfileLogRecord {
    public Dictionary<string,object> Record;
    public string Source,Time,Timestamp,Level,Event,Message,Operation,Related,Raw;
    public static string Text(Dictionary<string,object> d,string key) {object v;return d!=null&&d.TryGetValue(key,out v)&&v!=null?v.ToString():"";}
    public string Details() {
        var b=new StringBuilder();
        b.AppendLine(Message);b.AppendLine();
        b.AppendLine("时间："+Time+"    等级："+Level);
        b.AppendLine("行为："+ProfileLogViewer.EventTitle(Event)+" ("+Event+")");
        b.AppendLine("组件："+Text(Record,"component")+"    PID："+Text(Record,"pid"));
        b.AppendLine("操作编号："+Operation);
        if(Related!="")b.AppendLine("关联操作："+Related);
        b.AppendLine("来源："+Source);b.AppendLine("版本："+Text(Record,"build"));
        b.AppendLine("Worker SHA256："+Text(Record,"workerSha256"));
        b.AppendLine("配置 SHA256："+Text(Record,"settingsSha256"));
        b.AppendLine();b.AppendLine("判断证据 / 执行参数：");
        object data;if(Record.TryGetValue("data",out data))AppendObject(b,data,0);
        return b.ToString();
    }
    static void AppendObject(StringBuilder b,object value,int indent) {
        var d=value as Dictionary<string,object>;
        if(d!=null){foreach(var pair in d){b.Append(new string(' ',indent)).Append(FieldTitle(pair.Key)).Append(": ");if(pair.Value is Dictionary<string,object>||pair.Value is IList){b.AppendLine();AppendObject(b,pair.Value,indent+2);}else b.AppendLine(pair.Value==null?"--":pair.Value.ToString());}return;}
        var list=value as IList;
        if(list!=null){foreach(var item in list){b.Append(new string(' ',indent)).AppendLine("•");AppendObject(b,item,indent+2);}return;}
        b.Append(new string(' ',indent)).AppendLine(value==null?"--":value.ToString());
    }
    static string FieldTitle(string key) {
        var names=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase){{"mode","档位"},{"before","原档位"},{"after","目标档位"},{"freqMax","频率上限 MHz"},{"frequency","频率上限 MHz"},{"maxPercent","最大处理器比例 %"},{"minimum","最小处理器比例 %"},{"maximum","最大处理器比例 %"},{"reason","原因"},{"baseline","恢复快照"},{"safety","负载与进程证据"},{"active","附加省电生效"},{"code","规则代码"},{"observedAt","采样时间 UTC"},{"idleSeconds","无输入秒数"},{"inputIdleSeconds","无输入秒数"},{"operationId","操作编号"},{"enteredBy","进入时的操作编号"},{"Known","安全数据可信"},{"Game","游戏进程存在"},{"Protected","保护软件存在"},{"Process","阻止进程"},{"Cpu","CPU 总占用 %"},{"ProcessCpu","最高单进程 CPU %"},{"SingleCore","最高单进程一核算力 %"},{"Gpu","最忙 GPU 引擎 %"},{"TopCpuProcess","最高 CPU 进程"},{"stack","异常堆栈"},{"position","代码位置"},{"workerPid","执行进程 PID"},{"source","判断来源"},{"stage","失败阶段"},{"path","相关文件"},{"exceptionType","异常类型"},{"exitCode","进程退出码"},{"childOperationId","关联采样操作编号"}};
        string name;return names.TryGetValue(key,out name)?name+" ("+key+")":key;
    }
}
public sealed class ProfileLogViewer : Form {
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window,int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    static void ActivateNative(IntPtr window){ShowWindow(window,9);ShowWindow(window,5);SetForegroundWindow(window);}
    readonly string directory;
    readonly DateTimePicker date=new DateTimePicker();
    readonly ComboBox level=new ComboBox(),category=new ComboBox();
    readonly TextBox search=new TextBox();
    readonly ListView timeline=new ListView();
    readonly RichTextBox detail=new RichTextBox();
    readonly Label status=new Label();
    readonly Button traceButton=new Button();
    readonly BackgroundWorker loader=new BackgroundWorker();
    readonly Timer refresh=new Timer(),debounce=new Timer();
    List<ProfileLogRecord> records=new List<ProfileLogRecord>();
    HashSet<string> trace;
    bool pending;
    string fingerprint="";
    public int VisibleRecordCount {get{return timeline.Items.Count;}}
    public ProfileLogViewer(string root) {
        directory=Path.Combine(root,"logs");Text="PowerProfile · 日志";Font=new Font("Microsoft YaHei UI",9);
        ClientSize=new Size(880,680);MinimumSize=new Size(800,600);StartPosition=FormStartPosition.CenterScreen;
        BackColor=Color.FromArgb(247,249,250);Icon=(Icon)SystemIcons.Application.Clone();
        var header=new Label{Text="运行记录",Font=new Font(Font.FontFamily,15,FontStyle.Bold),Bounds=new Rectangle(20,16,260,30)};Controls.Add(header);
        var hint=new Label{Text="按时间查看事件，选中一项查看证据与恢复过程。",ForeColor=Color.FromArgb(100,110,119),Bounds=new Rectangle(20,51,720,25)};Controls.Add(hint);
        date.Format=DateTimePickerFormat.Custom;date.CustomFormat="yyyy-MM-dd";date.SetBounds(20,85,130,28);Controls.Add(date);
        level.DropDownStyle=ComboBoxStyle.DropDownList;level.Items.AddRange(new object[]{"全部级别","仅警告","仅错误"});level.SelectedIndex=0;level.SetBounds(162,85,110,28);Controls.Add(level);
        category.DropDownStyle=ComboBoxStyle.DropDownList;category.Items.AddRange(new object[]{"关键事件","全部事件","省电与恢复","档位切换","自动判断","界面与启动"});category.SelectedIndex=0;category.SetBounds(284,85,140,28);Controls.Add(category);
        search.SetBounds(438,85,270,28);search.AccessibleName="搜索原因、进程或操作编号";Controls.Add(search);
        var reset=new Button{Text="清除筛选",Bounds=new Rectangle(722,83,138,30)};reset.Click+=(s,e)=>{trace=null;search.Clear();level.SelectedIndex=0;category.SelectedIndex=1;ApplyFilters();};Controls.Add(reset);
        var searchHint=new Label{Text="搜索原因 / 进程 / 操作编号",ForeColor=hint.ForeColor,Bounds=new Rectangle(438,115,270,22)};Controls.Add(searchHint);
        var split=new SplitContainer{Bounds=new Rectangle(20,147,840,450),Anchor=AnchorStyles.Top|AnchorStyles.Bottom|AnchorStyles.Left|AnchorStyles.Right,Orientation=Orientation.Horizontal,SplitterDistance=225,BackColor=Color.FromArgb(230,234,238)};
        Controls.Add(split);
        timeline.Dock=DockStyle.Fill;timeline.View=View.Details;timeline.FullRowSelect=true;timeline.HideSelection=false;timeline.MultiSelect=false;timeline.BorderStyle=BorderStyle.None;
        timeline.Columns.Add("时间",105);timeline.Columns.Add("级别",65);timeline.Columns.Add("行为",170);timeline.Columns.Add("说明",475);split.Panel1.Controls.Add(timeline);
        detail.Dock=DockStyle.Fill;detail.ReadOnly=true;detail.BorderStyle=BorderStyle.None;detail.BackColor=Color.White;detail.Font=new Font("Microsoft YaHei UI",9);detail.DetectUrls=false;detail.Text="选择上方事件，查看可溯源详情。";split.Panel2.Controls.Add(detail);
        status.SetBounds(20,611,840,22);status.Anchor=AnchorStyles.Bottom|AnchorStyles.Left|AnchorStyles.Right;status.ForeColor=hint.ForeColor;Controls.Add(status);
        traceButton.Text="查看整次操作";traceButton.SetBounds(20,642,140,30);traceButton.Anchor=AnchorStyles.Bottom|AnchorStyles.Left;traceButton.Enabled=false;Controls.Add(traceButton);
        var copy=new Button{Text="复制详情",Bounds=new Rectangle(173,642,110,30),Anchor=AnchorStyles.Bottom|AnchorStyles.Left};Controls.Add(copy);copy.Click+=(s,e)=>{if(detail.Text.Length>0)try{Clipboard.SetText(detail.Text);}catch(Exception ex){status.Text="复制失败："+ex.Message;}};
        var reload=new Button{Text="刷新",Bounds=new Rectangle(621,642,110,30),Anchor=AnchorStyles.Bottom|AnchorStyles.Right};Controls.Add(reload);reload.Click+=(s,e)=>RequestLoad(true);
        var close=new Button{Text="关闭",Bounds=new Rectangle(744,642,116,30),Anchor=AnchorStyles.Bottom|AnchorStyles.Right};Controls.Add(close);close.Click+=(s,e)=>Close();
        timeline.SelectedIndexChanged+=(s,e)=>{if(timeline.SelectedItems.Count>0){detail.Text=((ProfileLogRecord)timeline.SelectedItems[0].Tag).Details();traceButton.Enabled=true;}else traceButton.Enabled=false;};
        traceButton.Click+=(s,e)=>{
            if(timeline.SelectedItems.Count==0)return;
            var selected=(ProfileLogRecord)timeline.SelectedItems[0].Tag;trace=ConnectedOperations(records,selected.Operation);search.Clear();category.SelectedIndex=1;level.SelectedIndex=0;ApplyFilters();
        };
        date.ValueChanged+=(s,e)=>{trace=null;RequestLoad(true);};level.SelectedIndexChanged+=(s,e)=>ApplyFilters();category.SelectedIndexChanged+=(s,e)=>ApplyFilters();
        debounce.Interval=250;debounce.Tick+=(s,e)=>{debounce.Stop();ApplyFilters();};search.TextChanged+=(s,e)=>{debounce.Stop();debounce.Start();};
        loader.DoWork+=(s,e)=>{int skipped;var list=ReadRecords(directory,(DateTime)e.Argument,out skipped);e.Result=new object[]{(DateTime)e.Argument,list,skipped};};
        loader.RunWorkerCompleted+=(s,e)=>{
            if(IsDisposed){loader.Dispose();return;}
            if(e.Error!=null){fingerprint="";status.Text="读取失败，将自动重试："+e.Error.Message;}
            else{
                var result=(object[])e.Result;
                if(((DateTime)result[0]).Date==date.Value.Date){records=(List<ProfileLogRecord>)result[1];ApplyFilters();if((int)result[2]>0)status.Text+=" · 跳过 "+result[2]+" 条不完整记录";}
            }
            if(pending){pending=false;RequestLoad(true);}
        };
        refresh.Interval=5000;refresh.Tick+=(s,e)=>RequestLoad(false);
        Shown+=(s,e)=>{ActivateNative(Handle);RequestLoad(true);refresh.Start();};
        FormClosed+=(s,e)=>{refresh.Stop();refresh.Dispose();debounce.Stop();debounce.Dispose();if(!loader.IsBusy)loader.Dispose();Icon.Dispose();};
    }
    public void SelectSearch(string query) {category.SelectedIndex=1;search.Text=query??"";ApplyFilters();}
    void RequestLoad(bool force) {
        if(IsDisposed)return;
        string stamp="";string stem="PowerProfile-"+date.Value.ToString("yyyy-MM-dd")+".jsonl";
        try{if(Directory.Exists(directory))foreach(string file in Directory.GetFiles(directory,stem+"*")){try{var info=new FileInfo(file);stamp+=file+info.Length+info.LastWriteTimeUtc.Ticks;}catch(IOException){stamp+="rotating";}}}
        catch(Exception ex){fingerprint="";status.Text="日志目录暂不可读："+ex.Message;return;}
        if(!force&&stamp==fingerprint)return;
        if(loader.IsBusy){pending=true;return;}
        fingerprint=stamp;status.Text="读取中…";loader.RunWorkerAsync(date.Value.Date);
    }
    void ApplyFilters() {
        if(timeline.IsDisposed)return;
        string selected=timeline.SelectedItems.Count>0?((ProfileLogRecord)timeline.SelectedItems[0].Tag).Source:"";
        timeline.BeginUpdate();timeline.Items.Clear();
        for(int i=records.Count-1;i>=0;i--){var r=records[i];
            if(level.SelectedIndex==1&&r.Level!="WARN")continue;if(level.SelectedIndex==2&&r.Level!="ERROR")continue;
            if(category.SelectedIndex==0&&(r.Event=="auto.decision"||r.Event=="worker.request"||r.Event=="tray.lifecycle"||r.Event=="ui.dashboard.open"))continue;
            if(category.SelectedIndex==2&&!r.Event.StartsWith("workstation."))continue;
            if(category.SelectedIndex==3&&!r.Event.StartsWith("profile."))continue;
            if(category.SelectedIndex==4&&r.Event!="auto.decision")continue;
            if(category.SelectedIndex==5&&!r.Event.StartsWith("ui.")&&!r.Event.StartsWith("tray."))continue;
            if(trace!=null&&!trace.Contains(r.Operation)&&!trace.Contains(r.Related))continue;
            if(search.Text.Trim()!=""&&r.Raw.IndexOf(search.Text.Trim(),StringComparison.OrdinalIgnoreCase)<0)continue;
            string time=r.Time.Length>=23?r.Time.Substring(11,12):r.Time;
            var item=new ListViewItem(new string[]{time,r.Level=="ERROR"?"错误":r.Level=="WARN"?"警告":"信息",EventTitle(r.Event),r.Message});item.Tag=r;
            if(r.Level=="ERROR")item.ForeColor=Color.FromArgb(162,57,61);else if(r.Level=="WARN")item.ForeColor=Color.FromArgb(156,111,30);
            timeline.Items.Add(item);if(r.Source==selected)item.Selected=true;
        }
        timeline.EndUpdate();status.Text="显示 "+timeline.Items.Count+" / "+records.Count+" 条 · 最近 2000 条 · 每 5 秒检查更新"+(trace!=null?" · 已关联整次操作":"");
        if(timeline.Items.Count==0)detail.Text="当前筛选没有事件。可选择“全部事件”、其他日期或清除筛选。";
    }
    public static HashSet<string> ConnectedOperations(List<ProfileLogRecord> records,string operation) {
        var ids=new HashSet<string>(StringComparer.OrdinalIgnoreCase);if(operation!="")ids.Add(operation);
        bool changed=true;while(changed){changed=false;foreach(var r in records)if(r.Related!=""&&(ids.Contains(r.Operation)||ids.Contains(r.Related))){if(ids.Add(r.Operation))changed=true;if(ids.Add(r.Related))changed=true;}}
        return ids;
    }
    public static string EventTitle(string e) {
        var titles=new Dictionary<string,string>{{"auto.decision","自动判断"},{"worker.request","派发操作"},{"worker.failed","执行失败"},{"profile.apply.start","开始切档"},{"profile.apply.success","切档完成"},{"workstation.decision","省电判断"},{"workstation.apply.start","开始附加省电"},{"workstation.apply.success","附加省电生效"},{"workstation.apply.failed","附加省电失败"},{"workstation.restore.request","请求恢复"},{"workstation.restore.start","开始恢复"},{"workstation.restore.success","恢复完成"},{"workstation.restore.failed","恢复失败"},{"ui.dashboard.open","打开状态窗口"},{"ui.dashboard.failed","窗口打开失败"},{"telemetry.availability","指标状态变化"},{"telemetry.timeout","采样超时"},{"tray.switch","切换托盘版本"},{"settings.workstation.saved","保存省电设置"}};
        string title;return titles.TryGetValue(e,out title)?title:e;
    }
    public static List<ProfileLogRecord> ReadRecords(string directory,DateTime date,out int skipped) {
        skipped=0;var result=new List<ProfileLogRecord>();var tail=new Queue<string[]>();
        var serializer=new JavaScriptSerializer{MaxJsonLength=131072};string stem=Path.Combine(directory,"PowerProfile-"+date.ToString("yyyy-MM-dd")+".jsonl");
        foreach(string path in new string[]{stem+".3",stem+".2",stem+".1",stem}) {
            if(!File.Exists(path))continue;
            using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))using(var reader=new StreamReader(stream,Encoding.UTF8,true)){
                int number=0;string line;while((line=reader.ReadLine())!=null){number++;if(line.Length>131072){skipped++;continue;}tail.Enqueue(new string[]{line,Path.GetFileName(path)+":"+number});if(tail.Count>2000)tail.Dequeue();}
            }
        }
        foreach(var entry in tail)try{
            var d=serializer.DeserializeObject(entry[0]) as Dictionary<string,object>;if(d==null||ProfileLogRecord.Text(d,"timestamp")==""){skipped++;continue;}
            object dataObject;var data=d.TryGetValue("data",out dataObject)?dataObject as Dictionary<string,object>:null;
            string ev=ProfileLogRecord.Text(d,"event"),operation=ProfileLogRecord.Text(d,"operationId");
            if(ev=="worker.request"||ev=="workstation.restore.request"){string child=ProfileLogRecord.Text(data,"operationId");if(child!="")operation=child;}
            if(ev=="telemetry.failed"||ev=="telemetry.timeout"){string child=ProfileLogRecord.Text(data,"childOperationId");if(child!="")operation=child;}
            string related=ProfileLogRecord.Text(data,"enteredBy");
            if(related==""&&ev=="workstation.decision"){var parent=ProfileLogRecord.Text(data,"operationId");if(parent!=operation)related=parent;}
            result.Add(new ProfileLogRecord{Record=d,Raw=entry[0],Source=entry[1],Timestamp=ProfileLogRecord.Text(d,"timestamp"),Time=ProfileLogRecord.Text(d,"localTime"),Level=ProfileLogRecord.Text(d,"level"),Event=ev,Message=ProfileLogRecord.Text(d,"message"),Operation=operation,Related=related});
        }catch{skipped++;}
        result.Sort((a,b)=>string.CompareOrdinal(a.Timestamp,b.Timestamp));return result;
    }
}
