# debian-ios/scripts/run-in-vm.ps1 -- host-side glue.
#
# WHY THIS SHAPE (HANDOFF 9.3): the rootfs must be assembled inside the VM's ext4,
# never over /mnt/* (9p/drvfs: no real hardlinks, broken symlink and permission
# semantics). So this script copies the recipe INTO the VM, runs it there, and
# copies only finished artefacts back out to E:.
#
# It is glue, not a tool: no logic that matters lives here.
#
# USAGE:
#   pwsh -File debian-ios/scripts/run-in-vm.ps1 -Action build
#   pwsh -File debian-ios/scripts/run-in-vm.ps1 -Action reproduce
#   pwsh -File debian-ios/scripts/run-in-vm.ps1 -Action smoke
param(
  [ValidateSet('build','reproduce','smoke','shell')]
  [string]$Action = 'build',
  [string]$Distro = 'Ubuntu-24.04',
  [string]$Repo   = 'E:\Reverseing\Arlo\debian-ios',
  [string]$VmRoot = '/root/arlo'
)
$ErrorActionPreference = 'Stop'

$wslRepo = '/mnt/' + ($Repo.Substring(0,1).ToLower()) + ($Repo.Substring(2) -replace '\\','/')
Write-Host "== syncing $Repo -> $VmRoot/src (VM ext4)" -ForegroundColor Cyan
wsl -d $Distro -- bash -c "mkdir -p $VmRoot/src/scripts $VmRoot/src/overlay $VmRoot/src/pins $VmRoot/dist $VmRoot/evidence; cp -a $wslRepo/scripts/. $VmRoot/src/scripts/; cp -a $wslRepo/overlay/. $VmRoot/src/overlay/; [ -d $wslRepo/pins ] && cp -a $wslRepo/pins/. $VmRoot/src/pins/; find $VmRoot/src -name '*.sh' -exec sed -i 's/\r`$//' {} + ; ls $VmRoot/src/scripts"

$cmd = switch ($Action) {
  'build'     { "bash $VmRoot/src/scripts/build-initramfs.sh --variant both --out $VmRoot/dist --cache $VmRoot/cache --work $VmRoot/work --overlay $VmRoot/src/overlay --pins $VmRoot/src/pins/bookworm-arm64.pins" }
  'reproduce' { "bash $VmRoot/src/scripts/check-reproducible.sh" }
  'smoke'     { "bash $VmRoot/src/scripts/smoke-test-qemu.sh" }
  'shell'     { "bash -l" }
}
Write-Host "== running: $cmd" -ForegroundColor Cyan
wsl -d $Distro -- bash -lc $cmd
if ($LASTEXITCODE -ne 0) { throw "VM action '$Action' failed with exit code $LASTEXITCODE" }

if ($Action -in @('build','reproduce','smoke')) {
  Write-Host "== copying finished artefacts out to $Repo" -ForegroundColor Cyan
  wsl -d $Distro -- bash -c "mkdir -p $wslRepo/dist $wslRepo/evidence; cp -f $VmRoot/dist/*.cpio.gz $VmRoot/dist/*.sha256 $VmRoot/dist/*.tsv $wslRepo/dist/ 2>/dev/null; cp -f $VmRoot/evidence/* $wslRepo/evidence/ 2>/dev/null; ls -l $wslRepo/dist $wslRepo/evidence"
}
