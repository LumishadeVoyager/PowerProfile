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
    internal Control RenderOwner;internal bool VirtualFocus;
    public ProfileGameView View;public bool Selected;public string AppId;public ProfileSteamArtwork Artwork;
    Bitmap cover,raster;bool requested;readonly ProfileHoverTip tip;int contentVersion,rasterVersion=-1,rasterSkin=-1;Size rasterSize;Font rasterFont;bool rasterSelected,rasterFocused;
    public ProfileGameCard(){SetStyle(ControlStyles.Selectable,true);Height=224;Padding=Padding.Empty;TabStop=true;Cursor=Cursors.Hand;AccessibleRole=AccessibleRole.PushButton;tip=new ProfileHoverTip(this);}
    public void Update(ProfileGameView view){if(View!=null&&View.Name==view.Name&&View.Duration==view.Duration&&View.Recent==view.Recent&&View.Detail==view.Detail&&View.Sessions==view.Sessions)return;contentVersion++;View=view;AccessibleName=view.Name;AccessibleDescription=view.Duration+" · "+view.Sessions+" 个片段；按 Enter 查看会话";tip.Update(view.Detail);Invalidate();}
    protected override void OnVisibleChanged(EventArgs e){base.OnVisibleChanged(e);RequestCover();}
    protected override void OnHandleCreated(EventArgs e){base.OnHandleCreated(e);RequestCover();}
    void RequestCover(){var owner=RenderOwner??this;if(requested||!owner.Visible||Artwork==null||View==null||!owner.IsHandleCreated)return;requested=true;Artwork.Request(View.Name,owner,(image,id)=>{if(IsDisposed){if(image!=null)image.Dispose();return;}cover=image;AppId=id;contentVersion++;if(RenderOwner!=null)RenderOwner.Invalidate(Bounds);else Invalidate();});}
    internal void Render(Graphics graphics){var e=new PaintEventArgs(graphics,ClientRectangle);OnPaintBackground(e);OnPaint(e);}
    internal void ActivateCard(){OnClick(EventArgs.Empty);}
    protected override void OnKeyDown(KeyEventArgs e){base.OnKeyDown(e);if(e.KeyCode==Keys.Enter||e.KeyCode==Keys.Space){OnClick(EventArgs.Empty);e.Handled=true;}}
    protected override void OnPaintBackground(PaintEventArgs e){
        RequestCover();if(raster==null||rasterSize!=Size||rasterVersion!=contentVersion||rasterSkin!=ProfileSkin.Revision||rasterFont!=Font||rasterSelected!=Selected||rasterFocused!=(Focused||VirtualFocus)){
            if(raster!=null)raster.Dispose();rasterSize=Size;rasterVersion=contentVersion;rasterSkin=ProfileSkin.Revision;rasterFont=Font;rasterSelected=Selected;rasterFocused=Focused||VirtualFocus;
            raster=new Bitmap(Math.Max(1,Width),Math.Max(1,Height),System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using(var g=Graphics.FromImage(raster))using(var clip=ProfileMotion.Round(new RectangleF(.5f,.5f,Width-1,Height-1),ProfileSkin.Liquid?18:12)){g.SetClip(clip);var paint=new PaintEventArgs(g,new Rectangle(Point.Empty,Size));base.OnPaintBackground(paint);PaintContents(paint);}
        }if(ProfileSkin.Liquid)ProfileSkin.Canvas(this,e.Graphics);else e.Graphics.Clear(Parent==null?ProfileTheme.Background:Parent.BackColor);e.Graphics.DrawImageUnscaled(raster,0,0);
    }
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);}
    void PaintContents(PaintEventArgs e){
        if(View==null)return;RequestCover();var g=e.Graphics;float f=Font.Size/9f;int pad=(int)(12*f),top=(int)(108*f);g.SmoothingMode=SmoothingMode.AntiAlias;
        using(var clip=ProfileMotion.Round(new RectangleF(1,1,Width-2,Height-2),16)){
            var saved=g.Save();g.SetClip(clip);
            if(cover!=null){float ratio=Math.Max(Width/(float)cover.Width,top/(float)cover.Height);float width=cover.Width*ratio,height=cover.Height*ratio;g.DrawImage(cover,(Width-width)/2,(top-height)/2,width,height);}
            else{using(var brush=new LinearGradientBrush(new Rectangle(0,0,Width,top),Color.FromArgb(33,62,93),Color.FromArgb(85,72,125),35))g.FillRectangle(brush,0,0,Width,top);using(var p=new Pen(Color.FromArgb(90,200,222,255),2*f)){g.DrawEllipse(p,Width/2-24*f,top/2-18*f,48*f,32*f);g.DrawLine(p,Width/2-15*f,top/2-2*f,Width/2-3*f,top/2-2*f);g.DrawLine(p,Width/2-9*f,top/2-8*f,Width/2-9*f,top/2+4*f);g.DrawEllipse(p,Width/2+7*f,top/2-5*f,4*f,4*f);} }
            g.Restore(saved);
        }
        g.TextRenderingHint=System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        using(var title=new Font(Font.FontFamily,10*f,FontStyle.Bold))using(var brush=new SolidBrush(ProfileTheme.Text))using(var format=new StringFormat{Trimming=StringTrimming.EllipsisCharacter,FormatFlags=StringFormatFlags.LineLimit})g.DrawString(View.Name,title,brush,new RectangleF(pad,top+8*f,Width-pad*2,36*f),format);
        using(var value=new Font(Font.FontFamily,16*f,FontStyle.Bold))using(var brush=new SolidBrush(ProfileTheme.Text))using(var format=new StringFormat{Trimming=StringTrimming.EllipsisCharacter,FormatFlags=StringFormatFlags.NoWrap})g.DrawString(View.Duration,value,brush,new RectangleF(pad,top+46*f,Width-pad*2,30*f),format);
        using(var brush=new SolidBrush(ProfileTheme.Muted))using(var format=new StringFormat{Trimming=StringTrimming.EllipsisCharacter,FormatFlags=StringFormatFlags.NoWrap})g.DrawString(View.Recent??"",Font,brush,new RectangleF(pad,top+80*f,Width-pad*2,20*f),format);
        if(Selected||Focused||VirtualFocus){using(var path=ProfileMotion.Round(new RectangleF(1,1,Width-3,Height-3),16))using(var pen=new Pen(ProfileTheme.Accent,2))g.DrawPath(pen,path);}
        if((Focused&&ShowFocusCues)||VirtualFocus)ControlPaint.DrawFocusRectangle(g,new Rectangle(5,5,Width-10,Height-10));
    }
    protected override void Dispose(bool disposing){if(disposing){tip.Dispose();if(cover!=null)cover.Dispose();if(raster!=null)raster.Dispose();}base.Dispose(disposing);}
}

// One native canvas for the game library. Cards remain reusable data/render
// objects; offscreen cards have no visible HWND and are never painted.
public sealed class ProfileGameGallery : Control {
    public int ItemWidth=200,MaximumColumns=2;bool laying;int focusIndex;readonly ProfileHoverTip tip;
    ProfileGameCard[] Cards {get{return Controls.OfType<ProfileGameCard>().ToArray();}}
    public ProfileGameGallery(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.Selectable,true);TabStop=true;Margin=Padding.Empty;tip=new ProfileHoverTip(this);AccessibleRole=AccessibleRole.List;AccessibleName="游戏卡片";}
    protected override void OnSizeChanged(EventArgs e){base.OnSizeChanged(e);Reflow();}
    protected override void OnControlAdded(ControlEventArgs e){base.OnControlAdded(e);var card=e.Control as ProfileGameCard;if(card!=null){card.Visible=false;card.RenderOwner=this;}Reflow();}
    public void Reflow(){if(laying||Width<1)return;laying=true;try{var cards=Cards;int columns=Math.Max(1,Math.Min(MaximumColumns,Width/(ItemWidth+10)));int y=0;for(int i=0;i<cards.Length;i+=columns){int rowHeight=0;for(int c=0;c<columns&&i+c<cards.Length;c++){var card=cards[i+c];card.SetBounds(c*Width/columns,y,Math.Max(100,Width/columns-card.Margin.Horizontal),card.Height);rowHeight=Math.Max(rowHeight,card.Height+card.Margin.Vertical);}y+=rowHeight;}int height=cards.Length==0?Math.Max(30,Font.Height+12):y;if(Height!=height)Height=height;focusIndex=Math.Max(0,Math.Min(focusIndex,cards.Length-1));Invalidate();}finally{laying=false;}}
    protected override void OnPaintBackground(PaintEventArgs e){if(ProfileSkin.Liquid)ProfileSkin.Canvas(this,e.Graphics);else e.Graphics.Clear(Parent==null?ProfileTheme.Background:Parent.BackColor);}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);var cards=Cards;for(int i=0;i<cards.Length;i++){var card=cards[i];if(!e.ClipRectangle.IntersectsWith(card.Bounds))continue;card.VirtualFocus=Focused&&ShowFocusCues&&focusIndex==i;var state=e.Graphics.Save();e.Graphics.TranslateTransform(card.Left,card.Top);card.Render(e.Graphics);e.Graphics.Restore(state);}}
    int Hit(Point point){var cards=Cards;for(int i=0;i<cards.Length;i++)if(cards[i].Bounds.Contains(point))return i;return -1;}
    ProfileSkinPanel ScrollPage(){for(Control c=Parent;c!=null;c=c.Parent){var page=c as ProfileSkinPanel;if(page!=null&&page.AutoScroll)return page;}return null;}
    protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);int index=Hit(e.Location);Cursor=index>=0?Cursors.Hand:Cursors.Default;tip.Update(index>=0?Cards[index].AccessibleDescription:"");}
    protected override void OnMouseDown(MouseEventArgs e){base.OnMouseDown(e);var page=ScrollPage();if(page!=null)page.CancelScrollAnimation();int index=Hit(e.Location);if(index>=0){focusIndex=index;Focus();Invalidate();}}
    protected override void OnMouseClick(MouseEventArgs e){base.OnMouseClick(e);int index=Hit(e.Location);if(e.Button==MouseButtons.Left&&index>=0)Cards[index].ActivateCard();}
    protected override bool IsInputKey(Keys key){return key==Keys.Left||key==Keys.Right||key==Keys.Up||key==Keys.Down||key==Keys.Enter||key==Keys.Space||base.IsInputKey(key);}
    protected override void OnKeyDown(KeyEventArgs e){base.OnKeyDown(e);var cards=Cards;if(cards.Length==0)return;int columns=Math.Max(1,Math.Min(MaximumColumns,Width/(ItemWidth+10))),step=0;if(e.KeyCode==Keys.Left)step=-1;if(e.KeyCode==Keys.Right)step=1;if(e.KeyCode==Keys.Up)step=-columns;if(e.KeyCode==Keys.Down)step=columns;if(step!=0){focusIndex=Math.Max(0,Math.Min(cards.Length-1,focusIndex+step));var page=ScrollPage();if(page!=null){page.CancelScrollAnimation();var bounds=RectangleToScreen(cards[focusIndex].Bounds);var viewport=page.RectangleToScreen(page.ClientRectangle);int dy=bounds.Top<viewport.Top?bounds.Top-viewport.Top:bounds.Bottom>viewport.Bottom?bounds.Bottom-viewport.Bottom:0;if(dy!=0)page.AutoScrollPosition=new Point(-page.AutoScrollPosition.X,Math.Max(0,-page.AutoScrollPosition.Y+dy));}Invalidate();e.Handled=true;}if(e.KeyCode==Keys.Enter||e.KeyCode==Keys.Space){cards[focusIndex].ActivateCard();e.Handled=true;}}
    protected override void OnGotFocus(EventArgs e){base.OnGotFocus(e);Invalidate();}
    protected override void OnLostFocus(EventArgs e){base.OnLostFocus(e);Invalidate();}
    protected override AccessibleObject CreateAccessibilityInstance(){return new GalleryAccessibility(this);}
    sealed class GalleryAccessibility : ControlAccessibleObject {
        readonly ProfileGameGallery owner;public GalleryAccessibility(ProfileGameGallery owner):base(owner){this.owner=owner;}
        public override int GetChildCount(){return owner.Cards.Length;}
        public override AccessibleObject GetChild(int index){return index>=0&&index<owner.Cards.Length?new CardAccessibility(owner,index):null;}
    }
    sealed class CardAccessibility : AccessibleObject {
        readonly ProfileGameGallery owner;readonly int index;ProfileGameCard Card {get{return index<owner.Cards.Length?owner.Cards[index]:null;}}
        public CardAccessibility(ProfileGameGallery owner,int index){this.owner=owner;this.index=index;}
        public override string Name {get{return Card==null?"":Card.AccessibleName;}set{}}
        public override string Description {get{return Card==null?"":Card.AccessibleDescription;}}
        public override AccessibleRole Role {get{return AccessibleRole.PushButton;}}
        public override AccessibleObject Parent {get{return owner.AccessibilityObject;}}
        public override Rectangle Bounds {get{return Card==null?Rectangle.Empty:owner.RectangleToScreen(Card.Bounds);}}
        public override string DefaultAction {get{return "查看会话";}}
        public override AccessibleStates State {get{return AccessibleStates.Focusable|AccessibleStates.Selectable|(Card!=null&&Card.Selected?AccessibleStates.Selected:AccessibleStates.None);}}
        public override void DoDefaultAction(){if(Card==null||owner.IsDisposed)return;if(owner.InvokeRequired)owner.BeginInvoke((Action)(()=>{if(Card!=null)Card.ActivateCard();}));else Card.ActivateCard();}
    }
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
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
