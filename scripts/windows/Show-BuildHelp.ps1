#requires -Version 7.0

# Prints the Windows entry points. This was Start-Help.ps1, a name that suggested
# it launched something; it only reports. Keep this listing in step with
# scripts/windows/ - it is the first thing a newcomer reads, and AGENTS.md
# section 5 is the other copy.

Write-Host "=== AccelerANTgine Run Scripts ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Available scripts:" -ForegroundColor White
Write-Host "  Invoke-ContainerBuild.ps1          - Build in the Windows container" -ForegroundColor Yellow
Write-Host "  Invoke-ContainerPythonBindings.ps1 - Build the Python bindings in it" -ForegroundColor Yellow
Write-Host "  Start-Windows.ps1                  - Run what a build produced, on the host" -ForegroundColor Yellow
Write-Host "      -Config Debug      ASan CLI check, fuzz-target report, commit + compile suites" -ForegroundColor Gray
Write-Host "      -Config Profile    CLI check plus the Google Benchmark perf suite" -ForegroundColor Gray
Write-Host "      -Config Release    CLI check only" -ForegroundColor Gray
Write-Host ""
Write-Host "Usage:" -ForegroundColor White
Write-Host "  .\Invoke-ContainerBuild.ps1" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Debug" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Debug -RunWebRtcSmoke -ServerUri ws://localhost:8443" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Profile" -ForegroundColor Gray
Write-Host "  .\Start-Windows.ps1 -Config Release" -ForegroundColor Gray
Write-Host ""
