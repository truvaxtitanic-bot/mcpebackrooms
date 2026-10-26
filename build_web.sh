#!/usr/bin/env bash
# Builds the MCPE 0.6.1 web game from web-build.zip, with everything in ./mod copied on top.
# Needs emcc on PATH. Output goes to ./_site
set -euo pipefail
ROOT="$(pwd)"
echo "Building the plain game, plus anything in ./mod or ./mod.zip"
echo "== 1/4 Unpacking web-build.zip"
rm -rf game
python3 - <<'PY'
import zipfile, os
z = zipfile.ZipFile("web-build.zip")
out = os.path.realpath("game")
for i in z.infolist():
    n = i.filename.replace("\\", "/")
    if n.endswith("/"):
        continue
    p = os.path.realpath(os.path.join(out, n))
    if not p.startswith(out + os.sep):
        continue
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(z.read(i))
PY
WB="$ROOT/game/web-build"

echo "== 2/4 Copying your changes on top of the game"
if [ -f mod.zip ]; then
  rm -rf _mod
  python3 - <<'PY'
import zipfile, os
z = zipfile.ZipFile("mod.zip")
out = os.path.realpath("_mod")
for i in z.infolist():
    n = i.filename.replace("\\", "/")
    if n.endswith("/") or "__MACOSX" in n:
        continue
    p = os.path.realpath(os.path.join(out, n))
    if not p.startswith(out + os.sep):
        continue
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(z.read(i))
PY
  if [ -d _mod/mod ]; then cp -rv _mod/mod/. "$WB/"; else cp -rv _mod/. "$WB/"; fi
fi
if [ -d mod ]; then
  cp -rv mod/. "$WB/"
fi

cd "$WB/project/emscripten"
rm -rf obj
mkdir obj

echo "== 3/4 Compiling"
cat > compile_one.sh <<'EOS'
#!/usr/bin/env bash
src="$1"
rel="${src#../../src/}"
obj="obj/${rel//\//_}.o"
if ! out=$(emcc -c "$src" -o "$obj" -O2 -std=c++17 -DOPENGL_ES -DUSE_VBO -DEMSCRIPTEN \
     -Wno-c++11-narrowing -Wno-register -Wno-unused-value -Wno-comment \
     -sUSE_SDL=2 -sUSE_LIBPNG=1 2>&1); then
  echo "::error::Compile failed: $src"
  echo "----- $src -----"
  echo "$out"
  exit 255
fi
EOS
chmod +x compile_one.sh

# warm up the SDL2 / libpng ports once so parallel jobs don't fight over downloading them
echo 'int main(){return 0;}' > warm.cpp
emcc warm.cpp -o warm.js -sUSE_SDL=2 -sUSE_LIBPNG=1 >/dev/null 2>&1 || true
rm -f warm.cpp warm.js warm.wasm

find ../../src -name '*.cpp' \
  | grep -Ev 'main_win|main_android|main_iOS|main_rpi|main_dedicated|AppPlatform_win32|AppPlatform_android|AppPlatform_iOS|AppPlatform_rpi|/main\.cpp|SoundSystemSL|/rhi/' \
  | sort > sources.txt
echo "Compiling $(wc -l < sources.txt) files on $(nproc) cores..."
xargs -a sources.txt -P "$(nproc)" -n 1 ./compile_one.sh

echo "== 4/4 Linking"
emcc obj/*.o -o index.html \
  -sASYNCIFY=1 -sUSE_SDL=2 -sUSE_LIBPNG=1 -sLEGACY_GL_EMULATION=1 -sGL_UNSAFE_OPTS=0 \
  -lopenal -lidbfs.js \
  --js-library mc_platform.js --shell-file shell.html \
  --preload-file ../../data@/data \
  -sALLOW_MEMORY_GROWTH=1 -sMAX_WEBGL_VERSION=2 -sASSERTIONS=2 \
  "-sEXPORTED_FUNCTIONS=['_main','_idbfsReady','_syncSaves','_malloc','_free']" \
  "-sEXPORTED_RUNTIME_METHODS=['FS','ccall','cwrap','lengthBytesUTF8','stringToUTF8']" \
  -O2

cd "$ROOT"
rm -rf _site
mkdir _site
for f in index.html index.js index.wasm index.data manifest.json sw.js mc_platform.js; do
  cp "$WB/project/emscripten/$f" _site/
done
echo "Build complete. Output is in ./_site"
ls -la _site
