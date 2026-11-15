using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

public sealed class ProfileUsageLogPoint {public DateTime Time;public bool? Game;public bool Decision;public bool Boundary;public string Mode;public string GameName;}
public sealed class ProfileUsagePowerEvent {public DateTime Time;public bool Awake;public bool Exact;}
public sealed class ProfileUsageLogCache {
    public int Version {get;set;}
    public DateTime UpdatedAt {get;set;}
    public bool SleepBoundariesAvailable {get;set;}
    public Dictionary<string,ProfileEnergyDay> Days {get;set;}
}
public sealed class ProfileUsageLogReader {
    readonly string root;readonly bool readSleepEvents;string fingerprint="";
    ProfileUsageLogCache cache;
    static readonly TimeZoneInfo ChinaZone=TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");
    public ProfileUsageLogReader(string root):this(root,true){}
    public ProfileUsageLogReader(string root,bool readSleepEvents){this.root=root;this.readSleepEvents=readSleepEvents;
        try{cache=new JavaScriptSerializer{MaxJsonLength=4*1024*1024}.Deserialize<ProfileUsageLogCache>(ProfileEnergyStore.Read(Path.Combine(root,"usage.logs.history.json")));Validate(cache);}
        catch{cache=new ProfileUsageLogCache{Days=new Dictionary<string,ProfileEnergyDay>()};}
    }
    public ProfileUsageLogCache Cache {get{return cache;}}
    static void Validate(ProfileUsageLogCache value){
        if(value==null || value.Days==null || value.Days.Count>401)throw new InvalidDataException();
        foreach(var entry in value.Days){DateTime date;var d=entry.Value;
            if(!DateTime.TryParseExact(entry.Key,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date) || d==null || !Finite(d.Seconds) || d.Seconds<0 || d.Seconds>86400 || !Finite(d.GameCoverageSeconds) || d.GameCoverageSeconds<0 || d.GameCoverageSeconds>d.Seconds+0.01 || (d.GameSeconds.HasValue && (!Finite(d.GameSeconds.Value) || d.GameSeconds<0 || d.GameSeconds>d.GameCoverageSeconds+0.01)))throw new InvalidDataException();
            if(d.ModeGameSeconds.HasValue && (!Finite(d.ModeGameSeconds.Value) || d.ModeGameSeconds<0 || !d.GameSeconds.HasValue || d.ModeGameSeconds>d.GameSeconds+0.01))throw new InvalidDataException();
        }
    }
    static bool Finite(double n){return !Double.IsNaN(n) && !Double.IsInfinity(n);}
    public static bool? GameSignal(string source){
        switch(source){case "ConfiguredGame":case "LibraryGame":case "Foreground3DLoad":case "ConfirmedForeground":case "BackgroundGrace":case "BackgroundGameLoad":return true;
        case "NoGameSignal":case "BackgroundInactive":case "WorkstationLocked":case "StartupGuard":return false;default:return null;}
    }
    static bool? LegacySignal(string message){
        foreach(string source in new[]{"ConfiguredGame","LibraryGame","Foreground3DLoad","ConfirmedForeground","BackgroundGrace","BackgroundGameLoad"})if(message.StartsWith(source+" ",StringComparison.Ordinal) || message==source)return true;
        if(message.StartsWith("无已确认游戏",StringComparison.Ordinal) || message.StartsWith("锁屏/",StringComparison.Ordinal) || message.StartsWith("后台游戏已低负载",StringComparison.Ordinal))return false;
        return null; // A manually selected Game profile is not evidence of a game.
    }
    static string NameFromReason(string reason){
        var library=Regex.Match(reason,@"library=([^;]+)");if(library.Success && !String.IsNullOrWhiteSpace(library.Groups[1].Value))return CleanName(library.Groups[1].Value.Trim());
        foreach(Match match in Regex.Matches(reason,@"(?:\[|=)([^=;\[\]\r\n]+?)\.exe\b",RegexOptions.IgnoreCase)){
            string name=match.Groups[1].Value.Trim();if(!Regex.IsMatch(name,@"^(?:powershell|pwsh|svchost|explorer|dwm|chrome|msedge|steamwebhelper|msedgewebview2|wallpaperui|System|csrss|nvcontainer|start_protected_game)$",RegexOptions.IgnoreCase))return CleanName(name);
        }return null;
    }
    static string CleanName(string value){var nba=Regex.Match(value,@"^NBA\s*2K(\d{2})$",RegexOptions.IgnoreCase);return nba.Success?"NBA 2K"+nba.Groups[1].Value:value;}
    static string ModeFrom(object value){string mode=Convert.ToString(value);return mode=="Game" || mode=="Idle" || mode=="Balanced" ? mode : null;}
    static IEnumerable<string> Lines(string path){
        using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var reader=new StreamReader(stream)){string line;while((line=reader.ReadLine())!=null)yield return line;}
    }
    public static ProfileUsageLogPoint ParseRecord(string line){
        try{
            var json=new JavaScriptSerializer{MaxJsonLength=512*1024};var record=json.Deserialize<Dictionary<string,object>>(line);
            object stamp,eventName,dataObject,message;DateTimeOffset time;
            if(record==null || !record.TryGetValue("timestamp",out stamp) || !DateTimeOffset.TryParse(Convert.ToString(stamp),CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out time) || !record.TryGetValue("event",out eventName))return null;
            record.TryGetValue("data",out dataObject);record.TryGetValue("message",out message);var data=dataObject as Dictionary<string,object>;
            string code=Convert.ToString(eventName);var point=new ProfileUsageLogPoint{Time=time.UtcDateTime};
            if(code=="tray.switch" || (code=="tray.lifecycle" && (Convert.ToString(message).Contains("[START]") || Convert.ToString(message).Contains("[EXIT]")))){point.Boundary=true;return point;}
            if(code=="auto.decision"){
                object source,mode;point.Decision=true;point.Game=data!=null && data.TryGetValue("source",out source)?GameSignal(Convert.ToString(source)):null;point.Mode=data!=null && data.TryGetValue("after",out mode)?ModeFrom(mode):null;point.GameName=point.Game==false?null:NameFromReason(Convert.ToString(message));return point;
            }
            if(code=="worker.request" || code=="workstation.decision")return point;
            if(code=="profile.apply.success"){object mode;point.Decision=true;point.Game=LegacySignal(Convert.ToString(message));point.Mode=data!=null && data.TryGetValue("mode",out mode)?ModeFrom(mode):null;point.GameName=point.Game==false?null:NameFromReason(Convert.ToString(message));return point;}
        }catch{}
        return null;
    }
    public static ProfileUsageLogPoint ParseLegacy(string line){
        try{
            DateTime local;if(line.Length<32 || !DateTime.TryParseExact(line.Substring(0,19),"yyyy-MM-dd HH:mm:ss",CultureInfo.InvariantCulture,DateTimeStyles.None,out local) || !line.Substring(19).TrimStart().StartsWith("switched to ",StringComparison.Ordinal))return null;
            int at=line.IndexOf("Reason: ",StringComparison.Ordinal);
            var mode=Regex.Match(line,@"switched to (Game|Idle|Balanced)\b");if(!mode.Success)return null;
            return new ProfileUsageLogPoint{Time=TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local,DateTimeKind.Unspecified),ChinaZone),Decision=true,Game=at<0?null:LegacySignal(line.Substring(at+8)),Mode=mode.Groups[1].Value,GameName=at<0?null:NameFromReason(line.Substring(at+8))};
        }catch{return null;}
    }
    sealed class Range {public DateTime Start,End;}
    static double Duration(List<Range> ranges){
        ranges.Sort((a,b)=>a.Start.CompareTo(b.Start));DateTime? start=null;DateTime end=DateTime.MinValue;double total=0;
        foreach(var range in ranges){if(!start.HasValue){start=range.Start;end=range.End;}else if(range.Start<=end){if(range.End>end)end=range.End;}else{total+=(end-start.Value).TotalSeconds;start=range.Start;end=range.End;}}
        return total+(start.HasValue?(end-start.Value).TotalSeconds:0);
    }
    static void Add(Dictionary<string,List<Range>> days,DateTime start,DateTime end){
        while(start<end){DateTime local=TimeZoneInfo.ConvertTimeFromUtc(start,ChinaZone);DateTime midnight=TimeZoneInfo.ConvertTimeToUtc(local.Date.AddDays(1),ChinaZone);DateTime until=end<midnight?end:midnight;string key=local.ToString("yyyy-MM-dd");
            if(!days.ContainsKey(key))days[key]=new List<Range>();days[key].Add(new Range{Start=start,End=until});start=until;}
    }
    static bool Crosses(List<DateTime> boundaries,DateTime start,DateTime end){int index=boundaries.BinarySearch(start);index=index<0?~index:index+1;return index<boundaries.Count && boundaries[index]<=end;}
    public static Dictionary<string,ProfileEnergyDay> Build(List<ProfileUsageLogPoint> points,List<DateTime> boundaries,DateTime utcNow){
        return BuildCore(points,boundaries,new List<Range>(),utcNow,false);
    }
    public static Dictionary<string,ProfileEnergyDay> BuildSessions(List<ProfileUsageLogPoint> points,List<ProfileUsagePowerEvent> power,DateTime utcNow){
        power=new List<ProfileUsagePowerEvent>(power);power.Sort((a,b)=>a.Time.CompareTo(b.Time));var pauses=new List<Range>();var boundaries=new List<DateTime>();
        foreach(bool exact in new[]{false,true}){DateTime? down=null;
            foreach(var e in power){if(e.Time>utcNow || e.Exact!=exact)continue;boundaries.Add(e.Time);if(!e.Awake){if(!down.HasValue)down=e.Time;}else if(down.HasValue){if(e.Time>down.Value)pauses.Add(new Range{Start=down.Value,End=e.Time});down=null;}}
            if(down.HasValue && down.Value<utcNow)pauses.Add(new Range{Start=down.Value,End=utcNow});}
        return BuildCore(points,boundaries,pauses,utcNow,true);
    }
    public static List<ProfileUsagePowerEvent> ParseSleepReport(string xml){
        var result=new List<ProfileUsagePowerEvent>();DateTimeOffset start,end;
        var sleep=Regex.Match(xml,@"<Data Name=['""]SleepTime['""]>([^<]+)</Data>");var wake=Regex.Match(xml,@"<Data Name=['""]WakeTime['""]>([^<]+)</Data>");
        if(sleep.Success && wake.Success && DateTimeOffset.TryParse(sleep.Groups[1].Value,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out start) && DateTimeOffset.TryParse(wake.Groups[1].Value,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out end) && end>start){result.Add(new ProfileUsagePowerEvent{Time=start.UtcDateTime,Awake=false,Exact=true});result.Add(new ProfileUsagePowerEvent{Time=end.UtcDateTime,Awake=true,Exact=true});}
        return result;
    }
    static Dictionary<string,ProfileEnergyDay> BuildCore(List<ProfileUsageLogPoint> points,List<DateTime> boundaries,List<Range> pauses,DateTime utcNow,bool sessions){
        var valid=points.FindAll(p=>p.Time<=utcNow && p.Time>=utcNow.AddDays(-400));valid.Sort((a,b)=>a.Time.CompareTo(b.Time));
        boundaries=new List<DateTime>(boundaries);foreach(var p in valid)if(p.Boundary)boundaries.Add(p.Time);boundaries.Sort();
        var awake=new Dictionary<string,List<Range>>();var coverage=new Dictionary<string,List<Range>>();var games=new Dictionary<string,List<Range>>();
        var modes=new Dictionary<string,List<Range>>();var names=new Dictionary<string,HashSet<string>>();
        ProfileUsageLogPoint previous=null,decision=null;
        foreach(var point in valid){
            if(point.Boundary){previous=null;decision=null;continue;}
            if(previous!=null){double seconds=(point.Time-previous.Time).TotalSeconds;if(seconds>0 && seconds<=90 && !Crosses(boundaries,previous.Time,point.Time))Add(awake,previous.Time,point.Time);}
            previous=point;
            if(!point.Decision)continue;
            if(decision!=null){double seconds=(point.Time-decision.Time).TotalSeconds;
                if(seconds>0 && seconds<=90 && decision.Game.HasValue && point.Game.HasValue && !Crosses(boundaries,decision.Time,point.Time)){
                    Add(coverage,decision.Time,point.Time);
                    if(decision.Game==point.Game){if(point.Game.Value)Add(games,decision.Time,point.Time);}
                    else {DateTime middle=decision.Time.AddSeconds(seconds/2);Add(games,decision.Game.Value?decision.Time:middle,decision.Game.Value?middle:point.Time);}
                }}
            decision=point;
        }
        if(sessions){
            ProfileUsageLogPoint mode=null;
            foreach(var point in valid){
                if(point.Boundary){if(SupportedMode(mode))AddMode(mode.Time,point.Time,mode.GameName,pauses,modes,names);mode=null;continue;}
                if(point.Mode==null)continue;
                if(SupportedMode(mode))AddMode(mode.Time,point.Time,mode.GameName,pauses,modes,names);
                if(point.Mode=="Game" && String.IsNullOrEmpty(point.GameName) && mode!=null && mode.Mode=="Game")point.GameName=mode.GameName;
                mode=point;
            }
            // An open session is extended only to a recent live observation, never for days.
            if(SupportedMode(mode) && (utcNow-mode.Time).TotalSeconds<=90)AddMode(mode.Time,utcNow,mode.GameName,pauses,modes,names);
            foreach(var pair in modes){
                if(!awake.ContainsKey(pair.Key))awake[pair.Key]=new List<Range>();awake[pair.Key].AddRange(pair.Value);
                if(!coverage.ContainsKey(pair.Key))coverage[pair.Key]=new List<Range>();coverage[pair.Key].AddRange(pair.Value);
                if(!games.ContainsKey(pair.Key))games[pair.Key]=new List<Range>();games[pair.Key].AddRange(pair.Value);
            }
        }
        var result=new Dictionary<string,ProfileEnergyDay>();
        foreach(var pair in awake){double known=coverage.ContainsKey(pair.Key)?Duration(coverage[pair.Key]):0;var labels=names.ContainsKey(pair.Key)?new List<string>(names[pair.Key]):new List<string>();labels.Sort(StringComparer.OrdinalIgnoreCase);string examples=String.Join("、",labels.ToArray());if(examples.Length>200)examples=examples.Substring(0,200);
            result[pair.Key]=new ProfileEnergyDay{Seconds=Duration(pair.Value),Source="Logs",GameCoverageSeconds=known,GameSeconds=known>0?(games.ContainsKey(pair.Key)?Duration(games[pair.Key]):0):(double?)null,ModeGameSeconds=modes.ContainsKey(pair.Key)?Duration(modes[pair.Key]):(double?)null,GameNames=examples};}
        return result;
    }
    static bool SupportedMode(ProfileUsageLogPoint point){return point!=null && point.Mode=="Game" && (point.Game==true || !String.IsNullOrEmpty(point.GameName));}
    static void AddMode(DateTime start,DateTime end,string name,List<Range> pauses,Dictionary<string,List<Range>> modes,Dictionary<string,HashSet<string>> names){
        if(end<=start)return;var pieces=new List<Range>{new Range{Start=start,End=end}};
        foreach(var pause in pauses){var next=new List<Range>();foreach(var piece in pieces){if(pause.End<=piece.Start || pause.Start>=piece.End)next.Add(piece);else{if(pause.Start>piece.Start)next.Add(new Range{Start=piece.Start,End=pause.Start});if(pause.End<piece.End)next.Add(new Range{Start=pause.End,End=piece.End});}}pieces=next;}
        double seconds=0;foreach(var piece in pieces)seconds+=(piece.End-piece.Start).TotalSeconds;if(seconds>86400)return;
        foreach(var piece in pieces){Add(modes,piece.Start,piece.End);DateTime at=piece.Start;while(at<piece.End){DateTime local=TimeZoneInfo.ConvertTimeFromUtc(at,ChinaZone);string key=local.ToString("yyyy-MM-dd");if(!names.ContainsKey(key))names[key]=new HashSet<string>(StringComparer.OrdinalIgnoreCase);if(!String.IsNullOrEmpty(name))names[key].Add(name);at=TimeZoneInfo.ConvertTimeToUtc(local.Date.AddDays(1),ChinaZone);}}
    }
    static List<ProfileUsagePowerEvent> SleepEvents(out bool available){
        var result=new List<ProfileUsagePowerEvent>();available=false;
        try{
            string xpath="*[System[((Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=42 or EventID=107 or EventID=109 or EventID=506 or EventID=507)) or (Provider[@Name='Microsoft-Windows-Kernel-General'] and (EventID=12 or EventID=13)) or (Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1)) and TimeCreated[timediff(@SystemTime) <= 34560000000]]]";
            var query=new EventLogQuery("System",PathType.LogName,xpath){ReverseDirection=true};
            using(var reader=new EventLogReader(query)){for(int i=0;i<4096;i++){using(var entry=reader.ReadEvent()){if(entry==null)break;if(entry.Id==1)result.AddRange(ParseSleepReport(entry.ToXml()));else if(entry.TimeCreated.HasValue)result.Add(new ProfileUsagePowerEvent{Time=entry.TimeCreated.Value.ToUniversalTime(),Awake=entry.Id==107 || entry.Id==507 || entry.Id==12});}}}available=true;
        }catch{}
        return result;
    }
    public ProfileUsageLogCache Refresh(DateTime utcNow){
        var files=new List<string>();string directory=Path.Combine(root,"logs");
        if(Directory.Exists(directory))foreach(var path in Directory.GetFiles(directory,"PowerProfile-*.jsonl*"))if(Regex.IsMatch(Path.GetFileName(path),@"^PowerProfile-\d{4}-\d{2}-\d{2}\.jsonl(?:\.[123])?$"))files.Add(path);
        string legacy=Path.Combine(root,"profile.log");if(File.Exists(legacy))files.Add(legacy);
        if(files.Count==0)return cache;
        files.Sort(StringComparer.Ordinal);var parts=new List<string>();foreach(var path in files){var f=new FileInfo(path);parts.Add(path+":"+f.Length+":"+f.LastWriteTimeUtc.Ticks);}
        string next=String.Join("|",parts.ToArray());if(next==fingerprint)return cache;
        var points=new List<ProfileUsageLogPoint>();
        foreach(var file in files)foreach(var line in Lines(file)){if(line.Length>512*1024)continue;var p=file==legacy?ParseLegacy(line):ParseRecord(line);if(p!=null)points.Add(p);}
        bool sleepAvailable=false;var power=readSleepEvents?SleepEvents(out sleepAvailable):new List<ProfileUsagePowerEvent>();var days=BuildSessions(points,power,utcNow);
        var merged=new Dictionary<string,ProfileEnergyDay>(cache.Days);string oldest=TimeZoneInfo.ConvertTimeFromUtc(utcNow,ChinaZone).AddDays(-400).ToString("yyyy-MM-dd");
        foreach(var pair in days)merged[pair.Key]=pair.Value;
        var remove=new List<string>();foreach(var key in merged.Keys)if(String.CompareOrdinal(key,oldest)<0)remove.Add(key);foreach(var key in remove)merged.Remove(key);
        var updated=new ProfileUsageLogCache{Version=3,Days=merged,UpdatedAt=utcNow,SleepBoundariesAvailable=sleepAvailable};Validate(updated);
        ProfileEnergyStore.Write(Path.Combine(root,"usage.logs.history.json"),new JavaScriptSerializer{MaxJsonLength=4*1024*1024}.Serialize(updated));cache=updated;fingerprint=next;return cache;
    }
    public static void Merge(Dictionary<string,ProfileEnergyDay> usage,ProfileUsageLogCache logs){
        foreach(var pair in logs.Days){ProfileEnergyDay day;
            if(!usage.TryGetValue(pair.Key,out day)){day=new ProfileEnergyDay();usage[pair.Key]=day;}
            // Older power summaries have no interval positions. Use the larger observed
            // coverage as a conservative lower bound instead of adding overlapping totals.
            day.Seconds=Math.Max(day.Seconds,pair.Value.Seconds);
            day.GameCoverageSeconds=Math.Max(day.GameCoverageSeconds,pair.Value.GameCoverageSeconds);
            if(pair.Value.GameSeconds.HasValue)day.GameSeconds=Math.Max(day.GameSeconds??0,pair.Value.GameSeconds.Value);
            if(pair.Value.ModeGameSeconds.HasValue)day.ModeGameSeconds=Math.Max(day.ModeGameSeconds??0,pair.Value.ModeGameSeconds.Value);
            day.GameNames=pair.Value.GameNames;
            day.UsageSource="日志 / 采样估算";
        }
    }
}
