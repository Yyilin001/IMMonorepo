from pathlib import Path
import json,zipfile,zlib,hashlib,subprocess,re
root=Path(__file__).resolve().parents[4]
apk=root/'IMAndroid/app/build/outputs/apk/release/app-release-unsigned.apk'
ndk=Path.home()/'Library/Android/sdk/ndk/30.0.16248370/toolchains/llvm/prebuilt/darwin-x86_64/bin'
stripped=root/'IMAndroid/app/build/intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib/arm64-v8a'
manifest=json.loads((root/'experiments/swift-android/build/shared-sdk-manifest.json').read_text())
merged=root/'IMAndroid/app/build/intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib/arm64-v8a'
assert all(hashlib.sha256((merged/n).read_bytes()).hexdigest()==v['sha256'] for n,v in manifest['libraries'].items())
rows=[];groups={};dependencies={};sections={}
with zipfile.ZipFile(apk) as z:
 for i in z.infolist():
  group='native' if i.filename.startswith('lib/') else 'dex' if i.filename.endswith('.dex') else 'resources' if i.filename.startswith('res/') or i.filename=='resources.arsc' else 'other'
  groups[group]=groups.get(group,0)+i.compress_size
  if group=='native':
   data=z.read(i);file=stripped/Path(i.filename).name;assert data==file.read_bytes()
   compressor=zlib.compressobj(6,zlib.DEFLATED,-15);compressed=compressor.compress(data)+compressor.flush()
   sections[file.name]=subprocess.check_output([ndk/'llvm-size','-A',file],text=True)
   assert '.debug_info' not in sections[file.name]
   dependencies[file.name]=re.findall(r'\(NEEDED\).*?\[(.*?)\]',subprocess.check_output([ndk/'llvm-readelf','-d',file],text=True))
   rows.append(dict(name=file.name,bytes=len(data),apkBytes=i.compress_size,deflate6Bytes=len(compressed)))
 assert not any('isolated_backend' in i.filename for i in z.infolist())
exports=subprocess.check_output([ndk/'llvm-nm','--dynamic','--defined-only',stripped/'libIMV2SharedSDK.so'],text=True).splitlines()
report=dict(apk=str(apk),bytes=apk.stat().st_size,sha256=hashlib.sha256(apk.read_bytes()).hexdigest(),groups=groups,zipOverhead=apk.stat().st_size-sum(groups.values()),libraries=sorted(rows,key=lambda r:-r['bytes']),sdkExportedSymbols=len(exports),nativeDebugSectionsAbsent=True,mergedMatchesCurrentNativeManifest=True,nativeCompressionOnlyEstimateBytes=apk.stat().st_size-sum(r['apkBytes']-r['deflate6Bytes'] for r in rows),compressionEstimateIsNotInstallableBuild=True,dependencies=dependencies,sections=sections)
out=root/'experiments/swift-android/verification/release-size-20261112';out.mkdir(exist_ok=True)
(out/'analysis.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['dependencies','sections']},indent=2))
