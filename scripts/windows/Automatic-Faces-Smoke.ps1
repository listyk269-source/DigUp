#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Models,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$DevelopmentGui,
    [string]$DevelopmentHelper
)
. "$PSScriptRoot/Common.ps1"
$testRoot=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $testRoot){throw 'Use a fresh evidence directory.'}
New-Item -ItemType Directory -Path $testRoot | Out-Null
$baseline=Join-Path $testRoot 'baseline'
& "$PSScriptRoot/Faces-Smoke.ps1" -People -Archive $Archive -Models $Models -OutputDirectory $baseline -DevelopmentGui $DevelopmentGui -DevelopmentHelper $DevelopmentHelper
$baselineResult=Get-Content -LiteralPath "$baseline/result.json" -Raw | ConvertFrom-Json
if($baselineResult.result -ne 'passed'){throw 'The real Faces/People baseline did not pass.'}
$modelsPath=[IO.Path]::GetFullPath($Models)
$package=Join-Path $baseline 'Приложение café'
$fixture=Join-Path $baseline 'Фото лица Ё café'
$index=Join-Path $baseline 'Private index'
$settings=Join-Path $baseline 'settings.json'
$cli=Join-Path $package 'helper/digup.exe'
$gui=if($DevelopmentGui){[IO.Path]::GetFullPath($DevelopmentGui)}else{Join-Path $package 'DigUp.exe'}
$photo=Join-Path $fixture 'FACE742 crew.jpg'
$video=Join-Path $fixture 'FACE742 Видео после двух секунд.mp4'
$captures=@('auto-waiting','auto-progress','auto-suggestions','auto-paused','auto-resumed')
$passes=[Collections.Generic.List[object]]::new()
foreach($pass in @('live','restart')){
    foreach($label in $captures){
        $old=Join-Path $index "capture-$label.png"
        if(Test-Path -LiteralPath $old){Remove-Item -LiteralPath $old}
    }
    if($pass -eq 'restart'){
        Copy-Item -LiteralPath $photo -Destination (Join-Path $fixture 'AUTO FACE742 После перезапуска.jpg')
    }
    $report=Join-Path $testRoot "gui-$pass.json"
    $start=[Diagnostics.ProcessStartInfo]::new($gui)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8; $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach($argument in @('--index',$index,'--models',$modelsPath,'--settings',$settings,'--debug-isolated',
        '--debug-auto-faces','--debug-query','FACE742','--debug-report',$report,'--debug-quit','--helper',$cli)){$start.ArgumentList.Add($argument)}
    foreach($name in @('DIGUP_WORKER_DIR','DIGUP_BACKENDS','DIGUP_FFMPEG','GGML_BACKEND_PATH','DIGUP_DEVICE','DIGUP_FACE_WORKER','DIGUP_FACE_DISABLE_GPU','DIGUP_FACE_GPU_DEVICE','DIGUP_CPU_ONLY')){
        $start.Environment.Remove($name) | Out-Null
    }
    $start.Environment['PATH']="$env:SystemRoot/System32;$env:SystemRoot"
    $start.Environment['DIGUP_MODELS']=$modelsPath
    $start.Environment['WEBVIEW2_USER_DATA_FOLDER']=Join-Path $index '.webview'
    $process=[Diagnostics.Process]::Start($start)
    try{
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $deadline=[DateTime]::UtcNow.AddMinutes(20)
        $addedLive=$false; $addedPaused=$false
        while(!$process.HasExited){
            if([DateTime]::UtcNow -gt $deadline){throw 'Automatic face GUI exceeded the bounded timeout.'}
            if($pass -eq 'live' -and !$addedLive -and (Test-Path -LiteralPath "$index/capture-auto-waiting.png")){
                # No CLI indexing call: the live native watcher must publish both files.
                Copy-Item -LiteralPath $photo -Destination (Join-Path $fixture 'AUTO FACE742 Новое фото.jpg')
                Copy-Item -LiteralPath $video -Destination (Join-Path $fixture 'AUTO FACE742 Новое видео.mp4')
                $addedLive=$true
            }
            if($pass -eq 'live' -and !$addedPaused -and (Test-Path -LiteralPath "$index/capture-auto-paused.png")){
                Copy-Item -LiteralPath $photo -Destination (Join-Path $fixture 'AUTO FACE742 Пауза.jpg')
                $addedPaused=$true
            }
            Start-Sleep -Milliseconds 100
        }
        [void]$process.WaitForExit(5000)
        if(!$stdout.Wait(5000) -or !$stderr.Wait(5000)){throw 'Automatic GUI left output handles open.'}
        $stdout.Result | Set-Content -LiteralPath "$testRoot/gui-$pass.stdout.txt" -Encoding utf8NoBOM
        $stderr.Result | Set-Content -LiteralPath "$testRoot/gui-$pass.stderr.txt" -Encoding utf8NoBOM
        if($process.ExitCode){throw "Automatic GUI exited with $($process.ExitCode)."}
        $ui=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        if($ui.error -or !$ui.features.autoFaces.passed){throw "Actual automatic face workflow failed ($pass): $($ui.error)"}
        $actual=$ui.features.autoFaces
        if($actual.phase -ne $pass -or $actual.manualFaceStarts -ne 0 -or $ui.nativeFaceStartRequests -ne 0){throw 'Automatic smoke must never manually start the face job.'}
        if(!$actual.negativeExclusion.passed -or !$actual.negativeExclusion.explicitPositiveControl -or !$actual.negativeExclusion.pendingCountMatches -or ($pass -eq 'restart' -and !$actual.negativeExclusion.ruleSurvivedRestart)){throw 'Persistent exclusions must suppress real new photo/video matches and agree with background counts across restart.'}
        if($pass -eq 'live' -and (!$addedLive -or !$addedPaused -or !$actual.workspacesClosedAtStart -or !$actual.startedWithoutWorkspace -or
            !$actual.realWatcherIndexedPhoto -or !$actual.realWatcherIndexedVideo -or !$actual.progressCapture.active -or !$actual.progressCapture.progressVisible -or
            !$actual.pauseRespected -or !$actual.resumedWithoutFaceStart -or
            $actual.pendingBefore -lt 3 -or $actual.pendingAfterAccept -ne ($actual.pendingBefore-1) -or $actual.pendingAfterReject -ne ($actual.pendingBefore-2) -or
            $actual.pendingAfterResume -ne ($actual.pendingAfterReject+1) -or !$actual.pausedForRestart)){
            throw 'Actual watcher, proposal count or pause/resume checks failed.'
        }
        if($pass -eq 'restart' -and (!$actual.pausePersisted -or !$actual.decisionsPersisted -or !$actual.idleStable)){
            throw 'Automatic pause, labels or idle stability failed after restart.'
        }
        foreach($label in $captures){
            $capture=Join-Path $index "capture-$label.png"
            if(Test-Path -LiteralPath $capture){
                $bytes=[IO.File]::ReadAllBytes($capture)
                if($bytes.Length -lt 24 -or [Convert]::ToHexString($bytes[0..7]) -ne '89504E470D0A1A0A'){throw 'Invalid native automatic-face capture.'}
                Copy-Item -LiteralPath $capture -Destination "$testRoot/capture-$pass-$label.png"
            }elseif($pass -eq 'live'){throw "Missing required native phase $label"}
        }
        $passes.Add($actual)
    }finally{
        if(!$process.HasExited){$process.Kill($true); [void]$process.WaitForExit(5000)}
        $process.Dispose()
    }
}
@{result='passed';realModels=$true;realLiveWatcher=$true;noManualFaceStart=$true;userInstallationModified=$false;
    developmentGui=[bool]$DevelopmentGui;developmentHelper=[bool]$DevelopmentHelper;
    archiveSha256=(Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant();passes=$passes;
    checks=@('existing People/Faces workflow','live native watcher photo and H.264 video','automatic face progress with workspaces closed',
        'genuine face/video suggestions','pending count matches actual proposals','accept and reject decrement counts',
        'pause prevents new inference','resume without face_start','pause and labels persist after restart','idle does not duplicate','system-only PATH')} |
    ConvertTo-Json -Depth 14 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Actual automatic face indexing and People proposal counts passed: $testRoot"
