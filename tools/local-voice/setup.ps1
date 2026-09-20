# One-time setup: Python 3.12 venv + CUDA PyTorch + FunASR deps + CosyVoice clone.
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Py = Join-Path $Root ".venv\Scripts\python.exe"

if (-not (Test-Path $Py)) {
  py -3.12 -m venv (Join-Path $Root ".venv")
}

& $Py -m pip install -U pip wheel
# RTX 50xx (sm_120): use cu128 PyTorch (cu124 has no sm_120 kernels).
$TorchTag = try { (& $Py -c "import torch; print(torch.__version__)") } catch { "" }
if ($TorchTag -notmatch "cu128") {
  & $Py -m pip install --upgrade --force-reinstall torch torchaudio --index-url https://download.pytorch.org/whl/cu128
} else {
  & $Py -m pip install -U torch torchaudio --index-url https://download.pytorch.org/whl/cu128
}
& $Py -m pip install -r (Join-Path $Root "requirements.txt")

$Cosy = Join-Path $Root "CosyVoice"
if (-not (Test-Path $Cosy)) {
  git clone --depth 1 https://github.com/FunAudioLLM/CosyVoice.git $Cosy
}
Push-Location $Cosy
git submodule update --init --recursive --depth 1
Pop-Location

$Out = Join-Path $Root "output"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Wav = Join-Path $Out "sample_en.wav"
if (-not (Test-Path $Wav) -or (Get-Item $Wav).Length -lt 1000) {
  Add-Type -AssemblyName System.Speech
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $s.SetOutputToWaveFile($Wav)
  $s.Speak("Hello, this is a local FunASR smoke test.")
  $s.Dispose()
}

Write-Host "Setup done. Run: .\.venv\Scripts\python.exe test_funasr.py"
