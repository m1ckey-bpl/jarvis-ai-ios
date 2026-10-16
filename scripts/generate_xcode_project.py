#!/usr/bin/env python3
"""Generate `JarvisApp.xcodeproj` from the repository's file tree.

Why a generator instead of a hand-edited project: Xcode project files are large,
mergetastic and must be regenerated whenever files move. This script keeps the
project in sync with the sources in one command, needs no macOS, and refuses to
write a project it cannot verify.

The app target compiles the app layer *and* the JarvisCore sources directly (the
same files the SwiftPM package builds for Linux tests), so a single project file
has no external package resolution step that could fail on CI.

Usage:  python3 scripts/generate_xcode_project.py [--check]
        --check  verify the committed project matches the file tree (CI mode)
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import sys

BUNDLE_ID = "ai.jarvis.assistant"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.9"
TARGET_NAME = "JarvisApp"
PROJECT_NAME = "JarvisApp"
APP_DIR = "JarvisApp"
CORE_DIR = "JarvisCore/Sources/JarvisCore"

SOURCE_EXTENSIONS = {".swift": "sourcecode.swift"}
RESOURCE_TYPES = {".xcassets": "folder.assetcatalog"}
PLIST_TYPE = "text.plist.xml"


def uuid_for(key: str) -> str:
    """Deterministic 24-hex-character object identifier."""
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


def collect(root: pathlib.Path, base: pathlib.Path) -> list[pathlib.Path]:
    """Every .swift file under base, plus asset catalogs, sorted for stability."""
    items: list[pathlib.Path] = []
    for path in sorted(base.rglob("*")):
        if path.is_dir():
            if path.suffix == ".xcassets":
                items.append(path)
            continue
        if path.suffix in SOURCE_EXTENSIONS:
            items.append(path)
    return items


class ProjectBuilder:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.objects: dict[str, str] = {}   # uuid -> serialised object body
        self.order: list[str] = []          # insertion order for stable output

    def add(self, key: str, body: str) -> str:
        identifier = uuid_for(key)
        if identifier not in self.objects:
            self.objects[identifier] = body
            self.order.append(identifier)
        return identifier

    # -- sections -----------------------------------------------------------
    def file_reference(self, path: pathlib.Path, file_type: str) -> str:
        relative = path.relative_to(self.root)
        return self.add(f"fileref:{relative}",
                        f'{{isa = PBXFileReference; lastKnownFileType = {file_type}; '
                        f'path = "{path.name}"; sourceTree = "<group>"; }};')

    def build_file(self, path: pathlib.Path, file_type: str, phase: str) -> str:
        reference = self.file_reference(path, file_type)
        relative = path.relative_to(self.root)
        return self.add(f"buildfile:{relative}:{phase}",
                        f"{{isa = PBXBuildFile; fileRef = {reference} /* {path.name} */; }};")

    def group(self, name: str, children: list[str], path: str | None = None) -> str:
        child_list = "\n".join(f"\t\t\t\t{child}," for child in children)
        path_line = f'\t\t\tpath = "{path}";\n' if path else ""
        return self.add(f"group:{name}:{path}",
                        "{\n"
                        "\t\t\tisa = PBXGroup;\n"
                        "\t\t\tchildren = (\n"
                        f"{child_list}\n"
                        "\t\t\t);\n"
                        f"{path_line}"
                        "\t\t\tsourceTree = \"<group>\";\n"
                        "\t\t};")


def build_settings(configuration: str) -> str:
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": SWIFT_VERSION,
        "TARGETED_DEVICE_FAMILY": "1,2",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP_DIR}/Info.plist",
        "MARKETING_VERSION": "1.0.0",
        "OTHER_LDFLAGS": '"-lsqlite3"',
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "VALIDATE_PRODUCT": "YES",
    }
    if configuration == "Debug":
        common.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": '"DEBUG=1 $(inherited)"',
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "MTL_FAST_MATH": "YES",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
        })
    else:
        common.update({
            "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "MTL_FAST_MATH": "YES",
            "SWIFT_COMPILATION_MODE": "wholemodule",
        })
    body = "\n".join(f"\t\t\t\t{key} = {value};" for key, value in sorted(common.items()))
    return ("{\n"
            "\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbuildSettings = {\n"
            f"{body}\n"
            "\t\t\t};\n"
            f"\t\t\tname = {configuration};\n"
            "\t\t};")


def scheme_xml() -> str:
    target_id = uuid_for("target:JarvisApp")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "JarvisApp.app"
               BlueprintName = "JarvisApp"
               ReferencedContainer = "container:JarvisApp.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "JarvisApp.app"
            BlueprintName = "JarvisApp"
            ReferencedContainer = "container:JarvisApp.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "JarvisApp.app"
            BlueprintName = "JarvisApp"
            ReferencedContainer = "container:JarvisApp.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def render(root: pathlib.Path) -> str:
    app_root = root / APP_DIR
    core_root = root / CORE_DIR
    builder = ProjectBuilder(root)

    # ---- sources and resources -------------------------------------------
    app_files = collect(root, app_root)
    core_files = collect(root, core_root)
    if not app_files:
        raise SystemExit(f"no app sources found under {app_root}")

    source_build_files: list[str] = []
    resource_build_files: list[str] = []

    def group_children(files: list[pathlib.Path], base: pathlib.Path) -> list[str]:
        """Builds a PBXGroup tree that mirrors the folder structure on disk."""
        by_directory: dict[pathlib.Path, list[pathlib.Path]] = {}
        for path in files:
            by_directory.setdefault(path.parent, []).append(path)
        directories = {path.parent for path in files}

        def emit(directory: pathlib.Path) -> list[str]:
            result: list[str] = []
            for path in sorted(by_directory.get(directory, [])):
                if path.suffix == ".xcassets":
                    result.append(builder.file_reference(path, RESOURCE_TYPES[".xcassets"]))
                    resource_build_files.append(
                        builder.build_file(path, RESOURCE_TYPES[".xcassets"], "Resources"))
                else:
                    result.append(builder.file_reference(path, SOURCE_EXTENSIONS[".swift"]))
                    source_build_files.append(
                        builder.build_file(path, SOURCE_EXTENSIONS[".swift"], "Sources"))
            for child in sorted(directory_ for directory_ in directories
                                if directory_.parent == directory and directory_ != directory):
                result.append(builder.group(f"{base.name}/{child.relative_to(base)}", emit(child),
                                            path=child.name))
            return result

        return emit(base)

    app_group_children = group_children(app_files, app_root)
    core_group_children = group_children(core_files, core_root)

    # Info.plist is referenced but never compiled or copied (INFOPLIST_FILE handles it).
    info_reference = builder.file_reference(app_root / "Info.plist", PLIST_TYPE)
    app_group_children.insert(0, info_reference)

    app_group = builder.group(APP_DIR, app_group_children, path=APP_DIR)
    core_group = builder.group("JarvisCore", core_group_children, path=CORE_DIR)

    # ---- product ----------------------------------------------------------
    product_reference = builder.add(
        "product:JarvisApp.app",
        '{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; '
        'path = "JarvisApp.app"; sourceTree = BUILT_PRODUCTS_DIR; };')
    products_group = builder.group("Products", [product_reference])
    main_group = builder.group("main", [core_group, app_group, products_group])

    # ---- phases -----------------------------------------------------------
    sources_phase = builder.add("phase:Sources",
                                "{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                                "\t\t\tfiles = (\n"
                                + "\n".join(f"\t\t\t\t{identifier}," for identifier in sorted(source_build_files))
                                + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
    frameworks_phase = builder.add("phase:Frameworks",
                                   "{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                                   "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
    resources_phase = builder.add("phase:Resources",
                                  "{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                                  "\t\t\tfiles = (\n"
                                  + "\n".join(f"\t\t\t\t{identifier}," for identifier in sorted(resource_build_files))
                                  + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")

    # ---- target and project ----------------------------------------------
    target_id = builder.add("target:JarvisApp",
                            "{\n"
                            "\t\t\tisa = PBXNativeTarget;\n"
                            "\t\t\tbuildConfigurationList = " + uuid_for("configlist:target") + ";\n"
                            "\t\t\tbuildPhases = (\n"
                            f"\t\t\t\t{sources_phase},\n"
                            f"\t\t\t\t{frameworks_phase},\n"
                            f"\t\t\t\t{resources_phase},\n"
                            "\t\t\t);\n"
                            "\t\t\tbuildRules = (\n\t\t\t);\n"
                            "\t\t\tdependencies = (\n\t\t\t);\n"
                            "\t\t\tname = " + TARGET_NAME + ";\n"
                            "\t\t\tproductName = " + TARGET_NAME + ";\n"
                            f"\t\t\tproductReference = {product_reference};\n"
                            "\t\t\tproductType = \"com.apple.product-type.application\";\n"
                            "\t\t};")

    project_id = builder.add("project:root",
                             "{\n"
                             "\t\t\tisa = PBXProject;\n"
                             "\t\t\tattributes = {\n"
                             "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
                             "\t\t\t\tLastSwiftUpdateCheck = 1500;\n"
                             "\t\t\t\tLastUpgradeCheck = 1500;\n"
                             "\t\t\t\tTargetAttributes = {\n"
                             f"\t\t\t\t\t{target_id} = {{\n"
                             "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
                             "\t\t\t\t\t};\n"
                             "\t\t\t\t};\n"
                             "\t\t\t};\n"
                             "\t\t\tbuildConfigurationList = " + uuid_for("configlist:project") + ";\n"
                             "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
                             "\t\t\tdevelopmentRegion = en;\n"
                             "\t\t\thasScannedForEncodings = 0;\n"
                             "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
                             f"\t\t\tmainGroup = {main_group};\n"
                             f"\t\t\tproductRefGroup = {products_group};\n"
                             "\t\t\tprojectDirPath = \"\";\n"
                             "\t\t\tprojectRoot = \"\";\n"
                             "\t\t\ttargets = (\n"
                             f"\t\t\t\t{target_id},\n"
                             "\t\t\t);\n"
                             "\t\t};")

    builder.add("configlist:project",
                "{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{uuid_for('config:project:Debug')},\n"
                f"\t\t\t\t{uuid_for('config:project:Release')},\n"
                "\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n"
                "\t\t\tdefaultConfigurationName = Release;\n\t\t};")
    builder.add("configlist:target",
                "{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{uuid_for('config:target:Debug')},\n"
                f"\t\t\t\t{uuid_for('config:target:Release')},\n"
                "\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n"
                "\t\t\tdefaultConfigurationName = Release;\n\t\t};")
    builder.add("config:project:Debug", build_settings("Debug"))
    builder.add("config:project:Release", build_settings("Release"))
    builder.add("config:target:Debug", build_settings("Debug"))
    builder.add("config:target:Release", build_settings("Release"))

    # ---- serialise --------------------------------------------------------
    sections = {
        "PBXBuildFile": [],
        "PBXFileReference": [],
        "PBXFrameworksBuildPhase": [],
        "PBXGroup": [],
        "PBXNativeTarget": [],
        "PBXProject": [],
        "PBXResourcesBuildPhase": [],
        "PBXSourcesBuildPhase": [],
        "XCBuildConfiguration": [],
        "XCConfigurationList": [],
    }
    for identifier in builder.order:
        body = builder.objects[identifier]
        isa = body.split("isa = ", 1)[1].split(";", 1)[0]
        sections[isa].append((identifier, body))

    out: list[str] = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
                      "\tobjectVersion = 56;", "\tobjects = {", ""]
    for name in sections:
        entries = sections[name]
        if not entries:
            continue
        out.append(f"/* Begin {name} section */")
        for identifier, body in entries:
            out.append(f"\t\t{identifier} = {body}")
        out.append(f"/* End {name} section */")
        out.append("")
    out.append("\t};")
    out.append(f"\trootObject = {project_id};")
    out.append("}")
    out.append("")
    return "\n".join(out)


def write(root: pathlib.Path, check: bool) -> int:
    project_dir = root / f"{PROJECT_NAME}.xcodeproj"
    project_file = project_dir / "project.pbxproj"
    scheme_file = project_dir / "xcshareddata" / "xcschemes" / f"{TARGET_NAME}.xcscheme"
    content = render(root)

    if check:
        problems = []
        if not project_file.exists() or project_file.read_text() != content:
            problems.append(f"{project_file} is out of date — run scripts/generate_xcode_project.py")
        if not scheme_file.exists() or scheme_file.read_text() != scheme_xml():
            problems.append(f"{scheme_file} is out of date")
        for problem in problems:
            print(f"ERROR: {problem}")
        return 1 if problems else 0

    project_dir.mkdir(parents=True, exist_ok=True)
    project_file.write_text(content)
    scheme_file.parent.mkdir(parents=True, exist_ok=True)
    scheme_file.write_text(scheme_xml())
    print(f"wrote {project_file}")
    print(f"wrote {scheme_file}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the committed project matches the file tree")
    parser.add_argument("--repo-ios-dir",
                        default=str(pathlib.Path(__file__).resolve().parents[1] / "ios"))
    args = parser.parse_args()
    return write(pathlib.Path(args.repo_ios_dir), args.check)


if __name__ == "__main__":
    sys.exit(main())
