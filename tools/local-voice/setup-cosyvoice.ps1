# Isolated venv for CosyVoice (FunASR uses .venv with different numpy/transformers).
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Py = Join-Path $Root ".venv-cosyvoice\Scripts\python.exe"

if (-not (Test-Path $Py)) {
  py -3.12 -m venv (Join-Path $Root ".venv-cosyvoice")
}

& $Py -m pip install -U pip wheel
# RTX 50xx (sm_120) needs CUDA 12.8 wheels, not cu124.
& $Py -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128
# torchaudio 2.11+ may pull torchcodec; bench scripts patch load via soundfile (see test_cosyvoice.py).
& $Py -m pip install "numpy==1.26.4" "scipy==1.11.4" "transformers==4.51.3" soundfile librosa
& $Py -m pip install HyperPyYAML conformer inflect x-transformers openai-whisper onnxruntime==1.18.0 pydantic==2.7.0 wetext pyworld
& $Py -m pip install modelscope==1.20.0 omegaconf hydra-core diffusers==0.29.0 lightning==2.2.4
& $Py -m pip install gdown==5.1.0 rich==13.7.1 matplotlib==3.7.5 onnx==1.16.0 "protobuf==4.25" wget torchmetrics rootutils pyarrow==18.1.0

$Cosy = Join-Path $Root "CosyVoice"
if (-not (Test-Path $Cosy)) {
  git clone --depth 1 https://github.com/FunAudioLLM/CosyVoice.git $Cosy
}
Push-Location $Cosy
git submodule update --init --recursive --depth 1
Pop-Location

Write-Host "CosyVoice venv ready."
Write-Host "  CosyVoice2: .\.venv-cosyvoice\Scripts\python.exe test_cosyvoice.py"
Write-Host "  Fun-CosyVoice3: .\.venv-cosyvoice\Scripts\python.exe test_cosyvoice3.py"
Write-Host "  Latency (stream TTFT): .\.venv-cosyvoice\Scripts\python.exe bench_cosyvoice3_latency.py"
