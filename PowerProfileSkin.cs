using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

// Shared by all workspace pages and secondary windows. No hardware or data access.
public static class ProfileSkin {
    public static string Kind="Standard";public static bool SystemBlur=true;
    public static bool Liquid {get{return Kind=="Liquid"&&!SystemInformation.HighContrast;}}
    public static int Revision;
    sealed class Scene {public Bitmap Image;public Size Size;public int Revision;}
    static readonly Dictionary<Form,Scene> scenes=new Dictionary<Form,Scene>();
    static readonly Dictionary<Form,int> windows=new Dictionary<Form,int>();
    static readonly HashSet<Control> wired=new HashSet<Control>();
    sealed class NativeState {public BorderStyle TextBorder;public FlatStyle ComboFlat;public DrawMode ComboDraw;public bool ListDraw;public TabDrawMode TabDraw;public int ButtonBorder;public DataGridViewCellBorderStyle Cells;public DataGridViewHeaderBorderStyle Headers;public Color? Track;}
    static readonly Dictionary<Control,NativeState> native=new Dictionary<Control,NativeState>();
    static readonly HashSet<Form> registered=new HashSet<Form>();
    static readonly ToolStripRenderer originalMenus=ToolStripManager.Renderer;
    static readonly ToolStripRenderer liquidMenus=new ProfileSkinMenuRenderer();
    static bool monitoring,refreshing;
    static readonly Dictionary<string,Bitmap> coats=new Dictionary<string,Bitmap>();static long coatBytes;
    public static void Changed(){Revision++;ToolStripManager.Renderer=Liquid?liquidMenus:originalMenus;foreach(var scene in scenes.Values){if(scene.Image!=null)scene.Image.Dispose();scene.Image=null;}ClearCoats();}
    static void ClearCoats(){foreach(var bitmap in coats.Values)bitmap.Dispose();coats.Clear();coatBytes=0;}
    public static void Set(string kind){Kind=kind=="Liquid"||kind=="ClassicGlass"?kind:"Standard";Changed();}
    public static void MonitorWindows(){if(monitoring)return;monitoring=true;Application.Idle+=(s,e)=>{
        if(refreshing)return;refreshing=true;
        try{foreach(Form f in Application.OpenForms.Cast<Form>().ToArray()){int revision;if(!windows.TryGetValue(f,out revision)||revision!=Revision){windows[f]=Revision;ProfileTheme.ApplyWindow(f);}}}
        finally{refreshing=false;}
    };}
    public static void Register(Form f){if(!registered.Add(f))return;if(!windows.ContainsKey(f))windows[f]=-1;f.Disposed+=(s,e)=>{windows.Remove(f);registered.Remove(f);Scene scene;if(scenes.TryGetValue(f,out scene)){if(scene.Image!=null)scene.Image.Dispose();scenes.Remove(f);}};}
    static Point Origin(Control c,Form f){var p=Point.Empty;for(Control at=c;at!=null&&at!=f;at=at.Parent){p.Offset(at.Left,at.Top);}return p;}
    static Bitmap SceneFor(Form f){
        Scene scene;if(!scenes.TryGetValue(f,out scene)){scene=new Scene();scenes[f]=scene;Register(f);}
        var size=new Size(Math.Max(1,f.ClientSize.Width),Math.Max(1,f.ClientSize.Height));
        if(scene.Image!=null&&scene.Size==size&&scene.Revision==Revision)return scene.Image;
        if(scene.Image!=null)scene.Image.Dispose();scene.Image=new Bitmap(size.Width,size.Height,System.Drawing.Imaging.PixelFormat.Format32bppPArgb);scene.Size=size;scene.Revision=Revision;
        using(var g=Graphics.FromImage(scene.Image)){
            var a=ProfileTheme.Dark?Color.FromArgb(15,25,45):Color.FromArgb(218,232,249);
            var b=ProfileTheme.Dark?Color.FromArgb(37,36,61):Color.FromArgb(241,234,250);
            using(var brush=new LinearGradientBrush(new Rectangle(Point.Empty,size),a,b,65))g.FillRectangle(brush,0,0,size.Width,size.Height);
            Glow(g,new RectangleF(-size.Width*.4f,-size.Height*.1f,size.Width*1.35f,size.Height*.7f),ProfileTheme.Dark?Color.FromArgb(80,42,126,176):Color.FromArgb(140,155,218,244));
            Glow(g,new RectangleF(size.Width*.3f,size.Height*.1f,size.Width*1.1f,size.Height*.9f),ProfileTheme.Dark?Color.FromArgb(65,120,66,158):Color.FromArgb(120,205,176,238));
            Glow(g,new RectangleF(-size.Width*.25f,size.Height*.6f,size.Width*1.4f,size.Height*.7f),ProfileTheme.Dark?Color.FromArgb(55,24,133,132):Color.FromArgb(125,176,230,221));
        }return scene.Image;
    }
    static void Glow(Graphics g,RectangleF bounds,Color color){using(var path=new GraphicsPath()){path.AddEllipse(bounds);using(var brush=new PathGradientBrush(path)){brush.CenterColor=color;brush.SurroundColors=new[]{Color.FromArgb(0,color)};g.FillPath(brush,path);}}}
    public static void Canvas(Control c,Graphics g){
        var saved=g.Save();try{g.SetClip(c.ClientRectangle,CombineMode.Intersect);
        if(!Liquid){g.Clear(c.BackColor.A==255?c.BackColor:ProfileTheme.Background);return;}
        var f=c as Form??c.FindForm();if(f==null){g.Clear(ProfileTheme.Background);return;}var origin=Origin(c,f);g.DrawImageUnscaled(SceneFor(f),-origin.X,-origin.Y);
        // Reconstruct ancestor glass at the child's coordinates, so transparent rows
        // and buttons do not cut rectangular holes into a containing glass card.
        var parents=new List<Control>();for(Control at=c.Parent;at!=null&&at!=f;at=at.Parent)if(at is ProfileSurface||at is GroupBox)parents.Add(at);
        parents.Reverse();foreach(var at in parents){var p=Origin(at,f);int inset=at is GroupBox?8:0;Coat(g,new RectangleF(p.X-origin.X+.5f,p.Y-origin.Y+inset+.5f,at.Width-1,at.Height-inset-1),18,false);}
        }finally{g.Restore(saved);}
    }
    public static void Glass(Control c,Graphics g,RectangleF bounds,float radius,bool selected,bool backgroundReady=false){
        if(bounds.Width<2||bounds.Height<2)return;g.SmoothingMode=SmoothingMode.AntiAlias;
        if(!backgroundReady){var saved=g.Save();using(var clip=ProfileMotion.Round(bounds,radius)){g.SetClip(clip,CombineMode.Intersect);Canvas(c,g);}g.Restore(saved);}Coat(g,bounds,radius,selected);
    }
    static void Coat(Graphics g,RectangleF bounds,float radius,bool selected){
        if(bounds.Width<2||bounds.Height<2)return;
        int w=(int)Math.Ceiling(bounds.Width)+2,h=(int)Math.Ceiling(bounds.Height)+2;
        // These are position-independent translucent layers. Scrolling only
        // composites a cached bitmap; gradients and radial glows are not rerun.
        string key=w+"|"+h+"|"+radius+"|"+selected+"|"+Revision;Bitmap layer;
        if(!coats.TryGetValue(key,out layer)){
            long bytes=(long)w*h*4;if(bytes>16*1024*1024){PaintCoat(g,bounds,radius,selected);return;}
            if(coats.Count>=96||coatBytes+bytes>24*1024*1024)ClearCoats();
            layer=new Bitmap(w,h,System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using(var canvas=Graphics.FromImage(layer))PaintCoat(canvas,new RectangleF(.5f,.5f,bounds.Width,bounds.Height),radius,selected);
            coats[key]=layer;coatBytes+=bytes;
        }
        g.DrawImageUnscaled(layer,(int)Math.Floor(bounds.X),(int)Math.Floor(bounds.Y));
    }
    static void PaintCoat(Graphics g,RectangleF bounds,float radius,bool selected){
        if(bounds.Width<2||bounds.Height<2)return;
        using(var path=ProfileMotion.Round(bounds,radius)){
            var state=g.Save();g.SetClip(path,CombineMode.Intersect);
            var top=ProfileTheme.Dark?Color.FromArgb(selected?135:105,74,106,142):Color.FromArgb(selected?210:175,255,255,255);
            var bottom=ProfileTheme.Dark?Color.FromArgb(110,23,37,61):Color.FromArgb(95,238,248,255);
            using(var fill=new LinearGradientBrush(bounds,top,bottom,80))g.FillPath(fill,path);
            if(selected)using(var fill=new SolidBrush(Color.FromArgb(ProfileTheme.Dark?45:24,ProfileTheme.Accent)))g.FillPath(fill,path);
            Glow(g,new RectangleF(bounds.X-bounds.Width*.4f,bounds.Y-bounds.Height*.8f,bounds.Width*1.4f,bounds.Height*1.2f),Color.FromArgb(ProfileTheme.Dark?30:110,Color.White));g.Restore(state);
            using(var edge=new Pen(ProfileTheme.Dark?Color.FromArgb(95,151,191,229):Color.FromArgb(210,Color.White),1.2f))g.DrawPath(edge,path);
        }
        using(var inner=ProfileMotion.Round(new RectangleF(bounds.X+1.8f,bounds.Y+1.8f,Math.Max(1,bounds.Width-3.6f),Math.Max(1,bounds.Height-3.6f)),Math.Max(2,radius-1)))using(var pen=new Pen(ProfileTheme.Dark?Color.FromArgb(22,Color.White):Color.FromArgb(22,51,92,143)))g.DrawPath(pen,inner);
    }
    public static void Plot(Control c,Graphics g){if(Liquid){Canvas(c,g);Glass(c,g,new RectangleF(.5f,.5f,c.Width-1,c.Height-1),16,false,true);}else g.Clear(c.BackColor);}
    static void PanelPaint(object sender,PaintEventArgs e){if(Liquid)Canvas((Control)sender,e.Graphics);}
    static void ButtonPaint(object sender,PaintEventArgs e){if(!Liquid)return;var b=(Button)sender;Canvas(b,e.Graphics);Glass(b,e.Graphics,new RectangleF(.5f,.5f,b.Width-1,b.Height-1),Math.Min(18,b.Height/2),b.Focused);TextRenderer.DrawText(e.Graphics,b.Text,b.Font,b.ClientRectangle,b.Enabled?ProfileTheme.Text:ProfileTheme.Muted,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);if(b.Focused)ControlPaint.DrawFocusRectangle(e.Graphics,Rectangle.Inflate(b.ClientRectangle,-5,-5));}
    static void CellPaint(object sender,DataGridViewCellPaintingEventArgs e){
        if(!Liquid||e.ColumnIndex<0)return;bool selected=(e.State&DataGridViewElementStates.Selected)!=0;var rect=e.CellBounds;
        e.CellStyle.ForeColor=Readable(e.CellStyle.ForeColor);
        using(var fill=new LinearGradientBrush(rect,selected?ProfileTheme.Selection:ProfileTheme.Surface,ProfileMotion.Mix(selected?ProfileTheme.Selection:ProfileTheme.Surface,ProfileTheme.Background,.3f),90))e.Graphics.FillRectangle(fill,rect);
        e.Paint(e.ClipBounds,e.PaintParts&~DataGridViewPaintParts.Background&~DataGridViewPaintParts.SelectionBackground);e.Handled=true;
    }
    public static void Wire(Control c){
        if(!wired.Add(c))return;c.Disposed+=(s,e)=>{wired.Remove(c);native.Remove(c);};
        if(c is Form){Register((Form)c);if(!(c is ProfileWorkspaceForm))c.Paint+=PanelPaint;}else if(c is Panel&&!(c is ProfileSurface)&&!(c is ProfileNavigation)&&!(c is ProfileSkinPanel))c.Paint+=PanelPaint;
        var group=c as GroupBox;if(group!=null)group.Paint+=(s,e)=>{if(!Liquid)return;Canvas(group,e.Graphics);Glass(group,e.Graphics,new RectangleF(.5f,8.5f,group.Width-1,group.Height-9),16,false);TextRenderer.DrawText(e.Graphics,group.Text,group.Font,new Rectangle(14,0,Math.Max(1,group.Width-28),group.Font.Height+3),group.ForeColor,TextFormatFlags.EndEllipsis);};
        var b=c as Button;if(b!=null&&!(b is ProfileActionButton))b.Paint+=ButtonPaint;
        var grid=c as DataGridView;if(grid!=null)grid.CellPainting+=CellPaint;
        var combo=c as ComboBox;if(combo!=null)combo.DrawItem+=(s,e)=>{if(!Liquid||e.Index<0)return;bool selected=(e.State&DrawItemState.Selected)!=0;using(var fill=new SolidBrush(selected?ProfileTheme.Selection:ProfileTheme.Surface))e.Graphics.FillRectangle(fill,e.Bounds);TextRenderer.DrawText(e.Graphics,combo.GetItemText(combo.Items[e.Index]),e.Font,Rectangle.Inflate(e.Bounds,-4,0),ProfileTheme.Text,TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);e.DrawFocusRectangle();};
        var list=c as ListView;if(list!=null){list.DrawColumnHeader+=(s,e)=>{if(!Liquid)return;using(var fill=new SolidBrush(ProfileTheme.Surface))e.Graphics.FillRectangle(fill,e.Bounds);TextRenderer.DrawText(e.Graphics,e.Header.Text,list.Font,Rectangle.Inflate(e.Bounds,-5,0),ProfileTheme.Muted,TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);};list.DrawItem+=(s,e)=>{if(Liquid)e.DrawDefault=true;};list.DrawSubItem+=(s,e)=>{if(Liquid)e.DrawDefault=true;};}
        var tabs=c as TabControl;if(tabs!=null)tabs.DrawItem+=(s,e)=>{if(!Liquid)return;var rect=tabs.GetTabRect(e.Index);using(var fill=new SolidBrush(e.Index==tabs.SelectedIndex?ProfileTheme.Selection:ProfileTheme.Surface))e.Graphics.FillRectangle(fill,rect);TextRenderer.DrawText(e.Graphics,tabs.TabPages[e.Index].Text,tabs.Font,rect,ProfileTheme.Text,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);};
        var field=c.GetType().GetField("BackgroundPainter");if(field!=null&&field.FieldType==typeof(Action<Control,Graphics>))field.SetValue(c,(Action<Control,Graphics>)Plot);
        c.ControlAdded+=(s,e)=>{ProfileTheme.Style(e.Control);};
        c.ForeColorChanged+=(s,e)=>{Color readable=Readable(c.ForeColor);if(readable!=c.ForeColor)c.ForeColor=readable;};
    }
    // Telemetry and status refreshes may still assign their original light-skin colors.
    // Preserve their semantic hue while making the new value readable on dark glass.
    static Color Readable(Color color){if(!ProfileTheme.Dark||SystemInformation.HighContrast||color.GetBrightness()>=.5f)return color;if(color.R>color.G*1.25f)return Color.FromArgb(255,157,151);if(color.G>color.R*1.2f&&color.G>=color.B)return Color.FromArgb(86,209,173);if(color.B>color.R*1.2f)return ProfileTheme.Accent;return ProfileTheme.Text;}
    public static void Native(Control c){
        Wire(c);var combo=c as ComboBox;var text=c as TextBoxBase;var button=c as Button;var list=c as ListView;var tabs=c as TabControl;var grid=c as DataGridView;
        NativeState state;if(!native.TryGetValue(c,out state)){state=new NativeState();if(combo!=null){state.ComboFlat=combo.FlatStyle;state.ComboDraw=combo.DrawMode;}if(text!=null)state.TextBorder=text.BorderStyle;if(button!=null)state.ButtonBorder=button.FlatAppearance.BorderSize;if(list!=null)state.ListDraw=list.OwnerDraw;if(tabs!=null)state.TabDraw=tabs.DrawMode;if(grid!=null){state.Cells=grid.CellBorderStyle;state.Headers=grid.ColumnHeadersBorderStyle;}native[c]=state;}
        if(combo!=null){combo.FlatStyle=Liquid?FlatStyle.Flat:state.ComboFlat;combo.DrawMode=Liquid?DrawMode.OwnerDrawFixed:state.ComboDraw;}
        if(text!=null)text.BorderStyle=Liquid?BorderStyle.FixedSingle:state.TextBorder;
        if(button!=null&&!(button is ProfileActionButton))button.FlatAppearance.BorderSize=Liquid?0:state.ButtonBorder;
        if(list!=null){list.OwnerDraw=Liquid||state.ListDraw;list.BackColor=ProfileTheme.Surface;list.ForeColor=ProfileTheme.Text;}
        if(tabs!=null)tabs.DrawMode=Liquid?TabDrawMode.OwnerDrawFixed:state.TabDraw;
        if(grid!=null){grid.CellBorderStyle=Liquid?DataGridViewCellBorderStyle.SingleHorizontal:state.Cells;grid.ColumnHeadersBorderStyle=Liquid?DataGridViewHeaderBorderStyle.None:state.Headers;}
        var track=c.GetType().GetField("TrackColor");if(track!=null&&track.FieldType==typeof(Color)){if(!state.Track.HasValue)state.Track=(Color)track.GetValue(c);track.SetValue(c,Liquid||ProfileTheme.Dark?ProfileTheme.Border:state.Track.Value);}
    }
}
public sealed class ProfileSkinPanel : Panel {
    readonly Timer scrollTimer=new Timer{Interval=15};double scrollTarget;bool stepping;
    public bool ScrollAnimating {get{return scrollTimer.Enabled;}}
    public void CancelScrollAnimation(){scrollTimer.Stop();}
    public ProfileSkinPanel(){DoubleBuffered=true;scrollTimer.Tick+=(s,e)=>{
        if(!Visible||!ProfileMotion.Allowed){scrollTimer.Stop();return;}int current=-AutoScrollPosition.Y,max=Math.Max(0,VerticalScroll.Maximum-VerticalScroll.LargeChange+1);scrollTarget=Math.Max(0,Math.Min(max,scrollTarget));double distance=scrollTarget-current;int next=Math.Abs(distance)<2?(int)scrollTarget:current+(int)(Math.Sign(distance)*Math.Max(1,Math.Ceiling(Math.Abs(distance)*.45)));
        stepping=true;try{AutoScrollPosition=new Point(-AutoScrollPosition.X,next);}finally{stepping=false;}if(next==(int)scrollTarget||next==current)scrollTimer.Stop();
    };}
    protected override void OnMouseWheel(MouseEventArgs e){
        if(!AutoScroll||!VerticalScroll.Visible||!ProfileMotion.Allowed||SystemInformation.MouseWheelScrollLines==0){base.OnMouseWheel(e);return;}
        if(!scrollTimer.Enabled)scrollTarget=-AutoScrollPosition.Y;int lines=SystemInformation.MouseWheelScrollLines;double step=lines<0?ClientSize.Height:Math.Max(1,lines)*Font.Height;
        scrollTarget=Math.Max(0,Math.Min(Math.Max(0,VerticalScroll.Maximum-VerticalScroll.LargeChange+1),scrollTarget-e.Delta/120.0*step));scrollTimer.Start();var handled=e as HandledMouseEventArgs;if(handled!=null)handled.Handled=true;
    }
    protected override void OnScroll(ScrollEventArgs e){if(!stepping)scrollTimer.Stop();base.OnScroll(e);}
    protected override void OnMouseDown(MouseEventArgs e){scrollTimer.Stop();base.OnMouseDown(e);}
    protected override void OnVisibleChanged(EventArgs e){if(!Visible)scrollTimer.Stop();base.OnVisibleChanged(e);}
    protected override void Dispose(bool disposing){if(disposing)scrollTimer.Dispose();base.Dispose(disposing);}
    protected override void OnPaintBackground(PaintEventArgs e){if(ProfileSkin.Liquid)ProfileSkin.Canvas(this,e.Graphics);else base.OnPaintBackground(e);}
}
public sealed class ProfileSkinMenuRenderer : ToolStripProfessionalRenderer {
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e){if(!ProfileSkin.Liquid){base.OnRenderToolStripBackground(e);return;}using(var brush=new LinearGradientBrush(e.AffectedBounds,ProfileTheme.Surface,ProfileTheme.Background,90))e.Graphics.FillRectangle(brush,e.AffectedBounds);}
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e){if(!ProfileSkin.Liquid){base.OnRenderMenuItemBackground(e);return;}if(e.Item.Selected)using(var path=ProfileMotion.Round(new RectangleF(3,1,e.Item.Width-6,e.Item.Height-2),9))using(var brush=new SolidBrush(ProfileTheme.Selection))e.Graphics.FillPath(brush,path);}
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e){if(ProfileSkin.Liquid)e.TextColor=e.Item.Enabled?ProfileTheme.Text:ProfileTheme.Muted;base.OnRenderItemText(e);}
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e){if(ProfileSkin.Liquid)e.ArrowColor=ProfileTheme.Text;base.OnRenderArrow(e);}
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e){if(!ProfileSkin.Liquid){base.OnRenderImageMargin(e);return;}using(var brush=new SolidBrush(ProfileTheme.Surface))e.Graphics.FillRectangle(brush,e.AffectedBounds);}
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e){if(!ProfileSkin.Liquid){base.OnRenderToolStripBorder(e);return;}using(var pen=new Pen(ProfileTheme.Border))e.Graphics.DrawRectangle(pen,0,0,e.ToolStrip.Width-1,e.ToolStrip.Height-1);}
}
