#requires -Version 7.0

Write-Host "=== AccelerANTgine Run Scripts ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Available scripts:" -ForegroundColor White
Write-Host "  Start-Build.ps1        - Build in the Windows container" -ForegroundColor Yellow
Write-Host "  Start-Windows.ps1      - Run what a build produced, on the host" -ForegroundColor Yellow
Write-Host "      -Config Debug      ASan CLI check, fuzz-target report, commit + compile suites" -ForegroundColor Gray
Write-Host "      -Config Profile    CLI check plus the Google Benchmark perf suite" -ForegroundColor Gray
Write-Host "      -Config Release    CLI check only" -ForegroundColor Gray
Write-Host ""
Write-Host "Usage:" -ForegroundColor White
Write-Host "  .\Start-Build.ps1" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Debug" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Debug -RunWebRtcSmoke -ServerUri ws://localhost:8443" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Profile" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Release" -ForegroundColor Gray
Write-Host ""
