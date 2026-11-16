# Pure presentation work in a dedicated runspace; no controls, device calls or files.
function Get-WorkspaceModelKey($State,$Group,$Count,$From,$To,$DayType){return "$($State.ObservedAt.Ticks)|$($State.UsageUpdatedAt.Ticks)|$($State.LocalDay)|$($State.Price)|$($State.TodayKWh)|$($State.MonthKWh)|$($State.Days.Count)|$Group|$Count|$From|$To|$DayType"}
function Get-WorkspaceEnergyData($State,[string]$Group='Day',[int]$Count=30,$From=$null,$To=$null,[int]$DayType=0){
 $key=Get-WorkspaceModelKey $State $Group $Count $From $To $DayType
 if($Script:WorkspaceModels -and $Script:WorkspaceModels.ContainsKey($key)){
  $cached=$Script:WorkspaceModels[$key];$periods=New-Object 'Collections.Generic.List[ProfileEnergyPeriod]';foreach($p in $cached.Periods){$periods.Add($p.Copy())}
  return @{Rows=$cached.Rows;Periods=$periods;Details=$cached.Details;Summary=$cached.Summary}
 };return Get-WorkspaceEnergyDataUncached $State $Group $Count $From $To $DayType
}
function Start-WorkspaceModels {
 param([string]$Page='')
 $w=$Script:Workspace;$t=$w.Tag;$page=if($Page){$Page}else{$w.ActivePage};if($page -notin @('Energy','Games')){return}
 $state=$Script:EnergyService.GetSnapshot();$group=@('Day','Week','Month')[$w.Group.SelectedIndex];$count=if($group -eq 'Day'){@(7,30,90)[$w.Range.SelectedIndex]}elseif($group -eq 'Week'){@(4,8,12)[$w.Range.SelectedIndex]}else{@(3,6,12)[$w.Range.SelectedIndex]};$bounds=if($page -eq 'Games'){@{Start=[DateTime]$state.LocalDay;End=[DateTime]$state.LocalDay}}else{Get-InsightsBounds $state $group $count $w}
 $signature=(@($page,$state.ObservedAt.Ticks,$state.UsageUpdatedAt.Ticks,$state.Price,$state.TodayKWh,$state.MonthKWh,$state.Days.Count,$state.LocalDay,$group,$count,$bounds.Start.Ticks,$bounds.End.Ticks,$w.DayFilter.SelectedIndex,$w.SourceFilter.SelectedIndex,$w.QualityFilter.SelectedIndex,$w.Insights.Metric.SelectedIndex,$w.LedgerSearch.Text,$w.GameRange.SelectedIndex,$w.GameSearch.Text) -join '|')
 if($page -eq 'Games'){$signature=Get-WorkspaceGameModelKey $state @(7,30,90,400)[$w.GameRange.SelectedIndex] $w.GameSearch.Text.Trim()}
 if($t.ModelJob){if($t.ModelJob.Page -ne $page -or $t.ModelJob.Signature -ne $signature){$t.ModelWanted=$true};return}
 if($page -eq 'Games' -and $t.GameModel -and $t.GameModel.Key -eq $signature){if($w.ActivePage -eq 'Games'){Update-WorkspaceGames $state;$t.PageSignatures['Games']=$signature};return}
 if($t.PageSignatures -and $t.PageSignatures[$page] -eq $signature){return};if($t.ModelSignature -eq $signature){if($t.ModelApplied -ne $signature -and $t.ModelState){Update-ProfileWorkspace $t.ModelState;$t.ModelApplied=$signature};return};$t.ModelSignature=$signature
 $names=@('Get-WorkspaceEnergyDataUncached','Get-WorkspaceModelKey','Format-EnergyCalendarDate','Format-EnergyCost','Format-EnergyDuration','Test-InsightsDay','Get-InsightsComparison','Get-InsightsBrief','Get-InsightsMean','Get-InsightsMetric','Format-InsightsValue','Format-InsightsMean','Get-WorkspaceGameModelKey','Get-WorkspaceGameModel','Get-WorkspaceGameRows')
 $definitions=$t.ModelDefinitions;if(-not $definitions){$definitions=($names|ForEach-Object {'function '+$_+' {'+(Get-Command $_).Definition+"`n}"}) -join "`n";$t.ModelDefinitions=$definitions}
 $script='param($state,$group,$count,$start,$end,$dayType,$metric,$gameCount,$page,$search)' + "`n"+$definitions+@'

$cache=@{}
function Get-WorkspaceEnergyData($State,[string]$Group='Day',[int]$Count=30,$From=$null,$To=$null,[int]$DayType=0){$key=Get-WorkspaceModelKey $State $Group $Count $From $To $DayType;if(-not $cache.ContainsKey($key)){$cache[$key]=Get-WorkspaceEnergyDataUncached $State $Group $Count $From $To $DayType};return $cache[$key]}
if($page -eq 'Games'){$game=Get-WorkspaceGameModel $state $gameCount $search;return ,@{Cache=$cache;Game=$game}}
$null=Get-WorkspaceEnergyData $state $group $count $start $end $dayType
$null=Get-WorkspaceEnergyData $state Day 1 $start $end
$null=Get-InsightsComparison $state $start $end $metric $dayType
$null=Get-InsightsBrief $state $start $end $metric $dayType
$null=Get-WorkspaceEnergyData $state Day $gameCount
return ,@{Cache=$cache;Game=$null}
'@
 $t.ModelWanted=$false;$ps=[PowerShell]::Create();[void]$ps.AddScript($script).AddArgument($state).AddArgument($group).AddArgument($count).AddArgument($bounds.Start).AddArgument($bounds.End).AddArgument($w.DayFilter.SelectedIndex).AddArgument($w.Insights.Metric.SelectedIndex).AddArgument(@(7,30,90,400)[$w.GameRange.SelectedIndex]).AddArgument($page).AddArgument($w.GameSearch.Text.Trim());$handle=$ps.BeginInvoke();$t.ModelJob=@{PowerShell=$ps;Handle=$handle;Page=$page;State=$state;Signature=$signature};$w.Footer.Text='正在准备视图…';$t.ModelTimer.Start()
}
function Complete-WorkspaceModels {
 $w=$Script:Workspace;if(-not $w -or $w.IsDisposed){return};$t=$w.Tag;$job=$t.ModelJob;if(-not $job -or -not $job.Handle.IsCompleted){return}
 $success=$false;try{$result=$job.PowerShell.EndInvoke($job.Handle);if($job.PowerShell.HadErrors){throw ($job.PowerShell.Streams.Error|Out-String)};$payload=$result[0].PSObject.BaseObject;if($payload.Cache.Count -gt 0){$Script:WorkspaceModels=$payload.Cache};if($payload.Game){$t.GameModel=$payload.Game};$t.ModelReady[$job.Page]=$true;$t.ModelState=$job.State;$success=$true;$t.EnergyKey='';$t.GameKey='';if($w.ActivePage -eq $job.Page -and -not $t.ModelWanted){Update-ProfileWorkspace $job.State;$t.ModelApplied=$job.Signature;$t.PageSignatures[$job.Page]=$job.Signature;$w.Footer.Text='● 已就绪'}}catch{$t.ModelSignature='';$w.Footer.Text='视图准备失败，可按 F5 重试';Write-ProfileEvent 'workspace.models.failed' $_.Exception.Message 'WARN'}finally{$job.PowerShell.Dispose();$t.ModelJob=$null;$t.ModelTimer.Stop()}
 if($success -and $w.ActivePage -ne $job.Page){$w.Footer.Text='● 已就绪'}
 if($w.ActivePage -ne $job.Page -or $t.ModelWanted){$t.ModelSignature='';Start-WorkspaceModels}
}
