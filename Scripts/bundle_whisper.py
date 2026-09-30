#!/usr/bin/env python3
"""Copy the built Whisper CLI and its libraries into a relocatable app helper."""

from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys


def run(*arguments: str) -> str:
    return subprocess.check_output(arguments, text=True)


def rpaths(binary: Path) -> list[str]:
    lines = run('/usr/bin/otool', '-l', str(binary)).splitlines()
    paths = []
    for index, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            paths.append(lines[index + 2].strip().split('path ', 1)[1].rsplit(' (offset ', 1)[0])
    return list(dict.fromkeys(paths))


def bundle(build: Path, destination: Path) -> None:
    cli = build / 'bin/whisper-cli'
    if not cli.is_file():
        raise RuntimeError('Build whisper-cli with Scripts/bootstrap_whisper.sh before building the app.')

    # Replace only the helper directory owned by this script, including old versions.
    if destination.exists():
        shutil.rmtree(destination)
    contents = destination / 'Contents'
    binary_directory = contents / 'MacOS'
    library_directory = contents / 'Frameworks'
    resources_directory = contents / 'Resources'
    binary_directory.mkdir(parents=True)
    library_directory.mkdir()
    resources_directory.mkdir()
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.voiceploeg.whisper-cli',
        'CFBundleExecutable': 'whisper-cli',
        'CFBundlePackageType': 'APPL',
        'CFBundleName': 'Whisper',
        'CFBundleVersion': '1',
        'LSUIElement': True,
    }))
    bundled_cli = binary_directory / 'whisper-cli'
    shutil.copy2(cli, bundled_cli)

    libraries = sorted(build.rglob('*.dylib'))
    real_libraries = []
    for source in libraries:
        target = library_directory / source.name
        if source.is_symlink():
            target.symlink_to(source.resolve().name)
        else:
            shutil.copy2(source, target)
            real_libraries.append(target)

    required_architectures = set(os.environ.get('ARCHS', '').split())
    for binary in [*real_libraries, bundled_cli]:
        available_architectures = set(run('/usr/bin/lipo', '-archs', str(binary)).split())
        if not required_architectures.issubset(available_architectures):
            raise RuntimeError(f'{binary.name} is missing app architectures. Run Scripts/bootstrap_whisper.sh.')
        dependencies = run('/usr/bin/otool', '-L', str(binary)).splitlines()[1:]
        for line in dependencies:
            if " (compatibility version " not in line:
                continue
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith('@rpath/'):
                if not (library_directory / dependency.removeprefix('@rpath/')).is_file():
                    raise RuntimeError(f'Missing bundled dependency: {dependency}')
            elif not dependency.startswith(('/usr/lib/', '/System/Library/')):
                raise RuntimeError(f'Nonportable dependency in {binary.name}: {dependency}')

        for path in rpaths(binary):
            run('/usr/bin/install_name_tool', '-delete_rpath', path, str(binary))
        relative_path = '@loader_path/../Frameworks' if binary == bundled_cli else '@loader_path'
        run('/usr/bin/install_name_tool', '-add_rpath', relative_path, str(binary))
        identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
        arguments = ['/usr/bin/codesign', '--force', '--sign', identity]
        if identity != '-':
            arguments += ['--options', 'runtime']
        run(*arguments, str(binary))

    source_root = build.parent
    shutil.copy2(source_root / 'LICENSE', resources_directory / 'LICENSE-whisper.txt')
    ggml_license = source_root / 'ggml/LICENSE'
    if ggml_license.is_file():
        shutil.copy2(ggml_license, resources_directory / 'LICENSE-ggml.txt')

    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
    run('/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime', str(destination))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: bundle_whisper.py <whisper-build-directory> <helper-destination>')
    bundle(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
