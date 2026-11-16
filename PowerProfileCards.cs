using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

public sealed class ProfileGameView {
    public string Name,Duration,Recent,Detail;public int Sessions;public double Fraction;
}
public sealed class ProfileSteamEntry {public string Name,AppId;}

// Artwork is decorative: no account API, process discovery or gameplay accounting.
public sealed class ProfileSteamArtwork {
    readonly string cache;readonly object gate=new object();readonly Queue<Action> requests=new Queue<Action>();int workers;
    readonly Dictionary<string,object> fileLocks=new Dictionary<string,object>();
    Dictionary<string,ProfileSteamEntry> catalog;string[] steamRoots;DateTime scanned=DateTime.MinValue;
    readonly Dictionary<string,DateTime> failed=new Dictionary<string,DateTime>();
    public ProfileSteamArtwork(string cache){this.cache=cache;}
    public static string Key(string name){return Regex.Replace((name??"").ToLowerInvariant(),@"[^\p{L}\p{Nd}]","");}
    static string Value(string text,string key){return Regex.Match(text,"\""+Regex.Escape(key)+"\"\\s+\"([^\"]+)\"").Groups[1].Value;}
    public static Dictionary<string,ProfileSteamEntry> ReadInstalled(string[] libraries){
        var found=new Dictionary<string,ProfileSteamEntry>();var ambiguous=new HashSet<string>();
        foreach(string library in libraries.Distinct(StringComparer.OrdinalIgnoreCase))try{
            string apps=Path.Combine(library,"steamapps");if(!Directory.Exists(apps))continue;
            foreach(string file in Directory.GetFiles(apps,"appmanifest_*.acf"))try{
                string text=File.ReadAllText(file),name=Value(text,"name"),id=Value(text,"appid"),key=Key(name);
                if(key.Length==0||!Regex.IsMatch(id,@"^[1-9][0-9]{0,9}$")||ambiguous.Contains(key))continue;
                ProfileSteamEntry old;if(found.TryGetValue(key,out old)&&old.AppId!=id){found.Remove(key);ambiguous.Add(key);continue;}
                found[key]=new ProfileSteamEntry{Name=name,AppId=id};
            }catch(IOException){}catch(UnauthorizedAccessException){}
        }catch(IOException){}catch(UnauthorizedAccessException){}
        return found;
    }
    void Catalog(){
        if(catalog!=null&&(DateTime.UtcNow-scanned).TotalMinutes<10)return;
        var roots=new List<string>();
        foreach(string key in new[]{@"HKEY_CURRENT_USER\Software\Valve\Steam",@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam",@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam"})
            foreach(string name in new[]{"SteamPath","InstallPath"}){var path=Registry.GetValue(key,name,null) as string;if(!String.IsNullOrEmpty(path)&&Directory.Exists(path))roots.Add(path);}
        steamRoots=roots.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();var libraries=new List<string>(steamRoots);
        foreach(string root in steamRoots)try{string vdf=Path.Combine(root,@"steamapps\libraryfolders.vdf");if(File.Exists(vdf))foreach(Match m in Regex.Matches(File.ReadAllText(vdf),"\"path\"\\s+\"([^\"]+)\""))libraries.Add(m.Groups[1].Value.Replace(@"\\",@"\"));}catch(IOException){}catch(UnauthorizedAccessException){}
        var current=ReadInstalled(libraries.ToArray());var saved=new Dictionary<string,ProfileSteamEntry>();
        string index=Path.Combine(cache,"catalog.tsv");
        if(File.Exists(index))foreach(string line in File.ReadAllLines(index)){var fields=line.Split('\t');if(fields.Length==2&&Regex.IsMatch(fields[1],@"^[1-9][0-9]{0,9}$"))saved[Key(fields[0])]=new ProfileSteamEntry{Name=fields[0],AppId=fields[1]};}
        foreach(var entry in current)saved[entry.Key]=entry.Value;
        catalog=saved;scanned=DateTime.UtcNow;Directory.CreateDirectory(cache);
        File.WriteAllLines(index+".tmp",saved.Values.Select(e=>e.Name.Replace('\t',' ').Replace('\n',' ').Replace('\r',' ')+"\t"+e.AppId));
        if(File.Exists(index))File.Delete(index);File.Move(index+".tmp",index);
    }
    static Bitmap Decode(string path){using(var file=File.OpenRead(path))using(var image=Image.FromStream(file)){if(image.Width<32||image.Height<32||image.Width>4096||image.Height>4096)throw new InvalidDataException();return new Bitmap(image);}}
    public static string HeaderUrl(string json,string appId){
        string url=Regex.Match(json,"\"header_image\"\\s*:\\s*\"([^\"]+)\"").Groups[1].Value.Replace(@"\/","/");Uri imageUri;
        if(!Regex.IsMatch(appId,@"^[1-9][0-9]{0,9}$")||!Uri.TryCreate(url,UriKind.Absolute,out imageUri)||imageUri.Scheme!="https"||!imageUri.IsDefaultPort||!imageUri.Host.EndsWith(".steamstatic.com",StringComparison.OrdinalIgnoreCase)||!imageUri.AbsolutePath.Contains("/steam/apps/"+appId+"/"))throw new InvalidDataException();
        return imageUri.AbsoluteUri;
    }
    static void Download(string url,string path,int limit){
        var request=(HttpWebRequest)WebRequest.Create(url);request.Timeout=5000;request.ReadWriteTimeout=5000;request.AllowAutoRedirect=false;request.UserAgent="PowerProfile/1.7 artwork";
        using(var response=request.GetResponse())using(var input=response.GetResponseStream())using(var output=File.Create(path)){
            byte[] buffer=new byte[16384];int n,total=0;while((n=input.Read(buffer,0,buffer.Length))>0){total+=n;if(total>limit)throw new InvalidDataException();output.Write(buffer,0,n);}
        }
    }
    Bitmap Load(string name,out string appId){
        appId=null;ProfileSteamEntry entry;string[] roots;object fileGate;
        lock(gate){Catalog();if(!catalog.TryGetValue(Key(name),out entry))return null;appId=entry.AppId;roots=steamRoots;if(!fileLocks.TryGetValue(appId,out fileGate)){fileGate=new object();fileLocks[appId]=fileGate;}}
        lock(fileGate){
        string cached=Path.Combine(cache,appId+"-header.jpg");
        foreach(string path in new[]{cached}.Concat(roots.Select(r=>Path.Combine(r,"appcache","librarycache",entry.AppId+"_header.jpg")) ))
            try{if(File.Exists(path))return Decode(path);}catch(IOException){}catch(ArgumentException){}catch(OutOfMemoryException){}
        lock(gate){DateTime at;if(failed.TryGetValue(appId,out at)&&(DateTime.UtcNow-at).TotalMinutes<10)return null;}
        string temp=cached+".tmp";
        try{
            try{Download("https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/"+appId+"/header.jpg",temp,4*1024*1024);}
            catch(WebException){
                // New Steam artwork uses hashed paths and localized filenames.
                // Resolve only the already matched app ID, never guess by title.
                string metadata=temp+".json";string json;
                try{Download("https://store.steampowered.com/api/appdetails?appids="+appId+"&l=schinese",metadata,2*1024*1024);json=File.ReadAllText(metadata);}finally{if(File.Exists(metadata))File.Delete(metadata);}
                Download(HeaderUrl(json,appId),temp,4*1024*1024);
            }
            var bitmap=Decode(temp);if(File.Exists(cached))File.Delete(cached);File.Move(temp,cached);return bitmap;
        }catch{lock(gate)failed[appId]=DateTime.UtcNow;try{if(File.Exists(temp))File.Delete(temp);}catch(IOException){}return null;}
        }
    }
    public void Request(string name,Control owner,Action<Bitmap,string> completed){
        Action work=delegate{
            if(owner.IsDisposed||!owner.IsHandleCreated)return;
            Bitmap image=null;string id=null;try{image=Load(name,out id);}catch{}
            var result=image;var app=id;
            try{if(owner.IsDisposed||!owner.IsHandleCreated){if(result!=null)result.Dispose();return;}owner.BeginInvoke((Action)(()=>{if(owner.IsDisposed){if(result!=null)result.Dispose();return;}completed(result,app);}));}
            catch(InvalidOperationException){if(result!=null)result.Dispose();}
        };
        lock(requests){requests.Enqueue(work);if(workers>=2)return;workers++;}
        ThreadPool.QueueUserWorkItem(delegate{while(true){Action next;lock(requests){if(requests.Count==0){workers--;return;}next=requests.Dequeue();}try{next();}catch{}}});
    }
}

public sealed class ProfileGameCard : ProfileSurface {
    public ProfileGameView View;public bool Selected;public string AppId;public ProfileSteamArtwork Artwork;
    Bitmap cover;bool requested;readonly ProfileHoverTip tip;
    public ProfileGameCard(){Height=224;Padding=Padding.Empty;TabStop=true;Cursor=Cursors.Hand;AccessibleRole=AccessibleRole.PushButton;tip=new ProfileHoverTip(this);}
    public void Update(ProfileGameView view){View=view;AccessibleName=view.Name;AccessibleDescription=view.Duration+" · "+view.Sessions+" 个片段；按 Enter 查看会话";tip.Update(view.Detail);Invalidate();}
    protected override void OnVisibleChanged(EventArgs e){base.OnVisibleChanged(e);RequestCover();}
    protected override void OnHandleCreated(EventArgs e){base.OnHandleCreated(e);RequestCover();}
    void RequestCover(){if(requested||!Visible||Artwork==null||View==null||!IsHandleCreated)return;requested=true;Artwork.Request(View.Name,this,(image,id)=>{cover=image;AppId=id;Invalidate();});}
    protected override void OnKeyDown(KeyEventArgs e){base.OnKeyDown(e);if(e.KeyCode==Keys.Enter||e.KeyCode==Keys.Space){OnClick(EventArgs.Empty);e.Handled=true;}}
    protected override void OnPaint(PaintEventArgs e){
        base.OnPaint(e);if(View==null)return;RequestCover();var g=e.Graphics;float f=Font.Size/9f;int pad=(int)(12*f),top=(int)(108*f);g.SmoothingMode=SmoothingMode.AntiAlias;
        using(var clip=ProfileMotion.Round(new RectangleF(1,1,Width-2,Height-2),16)){
            var saved=g.Save();g.SetClip(clip);
            if(cover!=null){float ratio=Math.Max(Width/(float)cover.Width,top/(float)cover.Height);float width=cover.Width*ratio,height=cover.Height*ratio;g.DrawImage(cover,(Width-width)/2,(top-height)/2,width,height);}
            else{using(var brush=new LinearGradientBrush(new Rectangle(0,0,Width,top),Color.FromArgb(33,62,93),Color.FromArgb(85,72,125),35))g.FillRectangle(brush,0,0,Width,top);using(var p=new Pen(Color.FromArgb(90,200,222,255),2*f)){g.DrawEllipse(p,Width/2-24*f,top/2-18*f,48*f,32*f);g.DrawLine(p,Width/2-15*f,top/2-2*f,Width/2-3*f,top/2-2*f);g.DrawLine(p,Width/2-9*f,top/2-8*f,Width/2-9*f,top/2+4*f);g.DrawEllipse(p,Width/2+7*f,top/2-5*f,4*f,4*f);} }
            g.Restore(saved);
        }
        using(var title=new Font(Font.FontFamily,10*f,FontStyle.Bold))TextRenderer.DrawText(g,View.Name,title,new Rectangle(pad,top+(int)(8*f),Width-pad*2,(int)(36*f)),ProfileTheme.Text,TextFormatFlags.WordBreak|TextFormatFlags.EndEllipsis);
        using(var value=new Font(Font.FontFamily,16*f,FontStyle.Bold))TextRenderer.DrawText(g,View.Duration,value,new Rectangle(pad,top+(int)(46*f),Width-pad*2,(int)(30*f)),ProfileTheme.Text,TextFormatFlags.EndEllipsis);
        TextRenderer.DrawText(g,View.Recent??"",Font,new Rectangle(pad,top+(int)(80*f),Width-pad*2,(int)(20*f)),ProfileTheme.Muted,TextFormatFlags.EndEllipsis);
        if(Selected||Focused){using(var path=ProfileMotion.Round(new RectangleF(1,1,Width-3,Height-3),16))using(var pen=new Pen(ProfileTheme.Accent,2))g.DrawPath(pen,path);}
        if(Focused&&ShowFocusCues)ControlPaint.DrawFocusRectangle(g,new Rectangle(5,5,Width-10,Height-10));
    }
    protected override void Dispose(bool disposing){if(disposing){tip.Dispose();if(cover!=null)cover.Dispose();}base.Dispose(disposing);}
}

public sealed class ProfilePowerToggle : Button {
    public bool? State;public bool Pending;
    public ProfilePowerToggle(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);TabStop=true;Cursor=Cursors.Hand;FlatStyle=FlatStyle.Flat;AccessibleRole=AccessibleRole.PushButton;}
    protected override void OnPaint(PaintEventArgs e){
        var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;if(ProfileSkin.Liquid)ProfileSkin.Canvas(this,g);else g.Clear(Parent.BackColor);
        float h=Height-4,w=Width-4;Color color=Enabled&&State==true?Color.FromArgb(24,173,143):ProfileTheme.Dark?Color.FromArgb(73,85,99):Color.FromArgb(196,207,217);
        using(var path=ProfileMotion.Round(new RectangleF(2,2,w,h),h/2))using(var brush=new SolidBrush(color))g.FillPath(brush,path);
        float d=h-6,x=State==true?Width-d-5:5;using(var brush=new SolidBrush(Color.White))g.FillEllipse(brush,x,5,d,d);
        if(!State.HasValue||Pending)TextRenderer.DrawText(g,Pending?"…":"?",Font,new Rectangle((int)x,4,(int)d,(int)d),Color.FromArgb(85,101,118),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
        if(Focused&&ShowFocusCues)ControlPaint.DrawFocusRectangle(g,new Rectangle(1,1,Width-2,Height-2));
    }
}

public sealed class ProfileDeviceCard : ProfileSurface {
    public readonly Label Title=new Label(),Status=new Label(),Detail=new Label(),Next=new Label();
    public readonly ProfilePowerToggle Toggle=new ProfilePowerToggle();public readonly Button Schedule=new ProfileActionButton(),More=new ProfileActionButton();
    public ProfileDeviceView View;public event EventHandler<ProfileWorkspaceCommand> Command;readonly ProfileHoverTip tip;
    public ProfileDeviceCard(){Height=218;Padding=Padding.Empty;tip=new ProfileHoverTip(this);Title.Name="title";Title.Font=new Font(Font.FontFamily,10,FontStyle.Bold);foreach(var label in new[]{Title,Status,Detail,Next}){label.AutoEllipsis=true;Controls.Add(label);}Next.Tag=Detail.Tag=Status.Tag="muted";Controls.Add(Toggle);Controls.Add(Schedule);Controls.Add(More);Schedule.Text="定时";More.Text="•••";More.AccessibleName="设备更多操作";Schedule.Click+=(s,e)=>Emit("DeviceSchedule");More.Click+=(s,e)=>ShowMenu();Toggle.Click+=(s,e)=>{if(View!=null&&!View.Pending&&View.State.HasValue)Emit(View.State.Value?"DeviceOff":"DeviceOn");};}
    void Emit(string action){if(Command!=null&&View!=null)Command(this,new ProfileWorkspaceCommand(action,View.Id));}
    public void Update(ProfileDeviceView d){
        View=d;Tag=d;Title.Text=(d.Favorite?"★ ":"")+d.Name;
        Status.Text=d.Pending?"正在操作 · 等待读回":!d.Online?"状态未知 / 已离线":d.State==true?"已开启":d.State==false?"已关闭":"状态未知";
        Detail.Text=d.Room+" · "+d.Details;Next.Text=d.Next;Toggle.State=d.State;Toggle.Pending=d.Pending;Toggle.Enabled=d.CanControl&&d.State.HasValue&&!d.Pending;Schedule.Enabled=d.CanControl&&!d.Pending;
        Toggle.AccessibleName=d.Name+"电源开关";Toggle.AccessibleDescription=Status.Text+"；"+(d.State==true?"点击关闭":"点击开启");
        AccessibleName=d.Name;AccessibleDescription=d.Status+"；"+d.Details+"；"+d.Next;tip.Update(AccessibleDescription);Invalidate(true);
    }
    void ShowMenu(){
        if(View==null)return;var menu=new ContextMenuStrip();
        Action<string,string,bool> add=(text,action,enabled)=>{var item=menu.Items.Add(text);item.Enabled=enabled;item.Click+=(s,e)=>Emit(action);};
        add("开启","DeviceOn",View.CanControl&&!View.Pending);add("关闭","DeviceOff",View.CanControl&&!View.Pending);menu.Items.Add(new ToolStripSeparator());
        add(View.Favorite?"取消收藏":"收藏","Favorite",true);add("别名 / 房间","DeviceEdit",true);menu.Closed+=(s,e)=>menu.Dispose();menu.Show(More,new Point(0,More.Height));
    }
    bool laying;
    protected override void OnLayout(LayoutEventArgs e){base.OnLayout(e);if(Title==null||laying)return;laying=true;try{
        float f=Math.Min(Font.Size/9f,Width/200f);int p=Math.Max(9,(int)(13*f)),w=Width-2*p,gap=Math.Max(4,(int)(4*f));
        Toggle.SetBounds(Width-p-(int)(50*f),(int)(16*f),(int)(50*f),(int)(28*f));
        Title.SetBounds(p,(int)(68*f),w,Math.Max((int)(28*f),Title.Font.Height+4));
        Status.SetBounds(p,Title.Bottom+gap,w,Math.Max((int)(21*f),Status.Font.Height+4));
        Detail.SetBounds(p,Status.Bottom+gap,w,Math.Max((int)(20*f),Detail.Font.Height+4));
        Next.SetBounds(p,Detail.Bottom+gap,w,Math.Max((int)(20*f),Next.Font.Height+4));
        int h=Math.Max((int)(29*f),Schedule.Font.Height+10),y=Next.Bottom+gap*2;Schedule.SetBounds(p,y,Math.Max(48,w-(int)(46*f)),h);More.SetBounds(Width-p-(int)(38*f),y,(int)(38*f),h);
        int height=Schedule.Bottom+p;if(Height!=height)Height=height;
    }finally{laying=false;}}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);float f=Math.Min(Font.Size/9f,Width/200f);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;Color color=View!=null&&View.State==true&&View.Online?Color.FromArgb(23,162,135):ProfileTheme.Muted;
        using(var brush=new SolidBrush(Color.FromArgb(24,color)))g.FillEllipse(brush,13*f,13*f,42*f,42*f);
        using(var pen=new Pen(color,2*f)){string kind=View==null?"":View.Kind;
            if(kind=="light"){g.DrawEllipse(pen,25*f,21*f,18*f,20*f);g.DrawLine(pen,30*f,43*f,38*f,43*f);g.DrawLine(pen,31*f,47*f,37*f,47*f);}
            else if(kind=="plug"){g.DrawRectangle(pen,24*f,22*f,20*f,23*f);g.DrawLine(pen,30*f,28*f,30*f,34*f);g.DrawLine(pen,38*f,28*f,38*f,34*f);g.DrawArc(pen,30*f,35*f,8*f,6*f,0,180);}
            else{g.DrawRectangle(pen,25*f,21*f,18*f,26*f);g.DrawEllipse(pen,30*f,36*f,8*f,8*f);g.DrawLine(pen,30*f,27*f,38*f,27*f);}
        }
    }
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
}
