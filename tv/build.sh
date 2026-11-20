#!/bin/bash
# Builds TvProbe.dll (netstandard2.1, runs on any .NET Core 3.0+ incl. Tizen TVs) against
# reference stubs of the three TizenFX assemblies it uses, then lays out the .tpk.
set -euo pipefail
D=/opt/dn/lib/dotnet
CSC="$D/dotnet $(ls -d $D/sdk/*/Roslyn/bincore/csc.dll | head -1)"
NS=$(ls -d $D/packs/NETStandard.Library.Ref/*/ref/netstandard2.1)
NSREFS=$(ls $NS/*.dll | sed 's/^/-r:/' | tr '\n' ' ')
P=$(cd "$(dirname "$0")" && pwd); B=$P/build;   # P: this folder (stubs/ and TvProbe/ are next to this script) rm -rf $B; mkdir -p $B/stubs $B/tpk/bin $B/tpk/res $B/tpk/shared/res $B/tpk/lib
cs() { $CSC -nologo -nostdlib -noconfig -deterministic $NSREFS "$@"; }
cs -target:library -out:$B/stubs/Tizen.Applications.Common.dll $P/stubs/Common.cs
cs -target:library -out:$B/stubs/Tizen.Applications.Service.dll -r:$B/stubs/Tizen.Applications.Common.dll $P/stubs/Service.cs
cs -target:library -out:$B/stubs/Tizen.System.Information.dll $P/stubs/Information.cs
cs -target:exe -langversion:10 -unsafe -optimize+ -nowarn:CS8632 -out:$B/tpk/bin/TvProbe.dll \
   -r:$B/stubs/Tizen.Applications.Common.dll -r:$B/stubs/Tizen.Applications.Service.dll -r:$B/stubs/Tizen.System.Information.dll \
   $P/TvProbe/*.cs
cp $P/TvProbe/tizen-manifest.xml $B/tpk/
cp $P/TvProbe/res/probe.json $B/tpk/res/
cp $P/TvProbe/shared/res/TvProbe.png $B/tpk/shared/res/
VER=$(grep -o 'package="TrCeviri01" version="[0-9.]*"' $P/TvProbe/tizen-manifest.xml | cut -d'"' -f4)
OUT=/mnt/user-data/outputs/TrCeviri01-$VER.tpk; rm -f $OUT
(cd $B/tpk && zip -qrX $OUT tizen-manifest.xml bin res shared lib)
unzip -l $OUT
