#requires -Version 7.0

Write-Host "=== AccelerANTgine Run Scripts ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Available scripts:" -ForegroundColor White
Write-Host "  Start-Build.ps1   - Build in the Windows container" -ForegroundColor Yellow
Write-Host "  Start-Debug.ps1   - Debug build with ASan, fuzz tests, commit/compile tests" -ForegroundColor Yellow
Write-Host "  Start-Profile.ps1 - Profile build with perf tests" -ForegroundColor Yellow
Write-Host "  Start-Release.ps1 - Release build, CLI only" -ForegroundColor Yellow
Write-Host ""
Write-Host "Usage:" -ForegroundColor White
Write-Host "  .\Start-Build.ps1" -ForegroundColor Gray
Write-Host "  .\Start-Debug.ps1" -ForegroundColor Gray
Write-Host "  .\Start-Debug.ps1 -RunWebRtcSmoke -ServerUri ws://localhost:8443" -ForegroundColor Gray
Write-Host "  .\Start-Profile.ps1" -ForegroundColor Gray
Write-Host "  .\Start-Release.ps1" -ForegroundColor Gray
Write-Host ""
