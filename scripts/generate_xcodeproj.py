#!/usr/bin/env python3
"""生成 LocalLLMiOS.xcodeproj/project.pbxproj。

本机没有完整 Xcode 时也能产出可直接在 Xcode 打开的工程。
源码清单自动扫描 LocalLLMiOS/ 下所有 .swift；ID 由路径哈希生成，稳定可复现。
用法：python3 scripts/generate_xcodeproj.py
"""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "LocalLLMiOS"
OUT = ROOT / "LocalLLMiOS.xcodeproj" / "project.pbxproj"
XCF_REL = "Vendor/build-apple/llama.xcframework"
BRIDGING_REL = "LocalLLMiOS/App/Bridging-Header.h"
INFOPLIST_REL = "LocalLLMiOS/App/Info.plist"
PRODUCT = "LocalLLMiOS.app"
BUNDLE_ID = "com.idea2real.LocalLLMiOS"


def oid(key: str) -> str:
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:24].upper()


def ref_id(rel: str) -> str:
    return oid("ref:" + rel)


def build_id(rel: str, tag: str = "src") -> str:
    return oid(f"build:{tag}:{rel}")


def group_id(rel: str) -> str:
    return oid("group:" + rel)


PROJECT = oid("project")
TARGET = oid("target")
MAIN_GROUP = oid("group:main")
PRODUCTS_GROUP = oid("group:products")
FRAMEWORKS_GROUP = oid("group:frameworks")
SOURCES_PHASE = oid("phase:sources")
FRAMEWORKS_PHASE = oid("phase:frameworks")
EMBED_PHASE = oid("phase:embed")
RESOURCES_PHASE = oid("phase:resources")
PROJ_CONF_LIST = oid("conflist:project")
TARGET_CONF_LIST = oid("conflist:target")
PROJ_DEBUG = oid("conf:project:debug")
PROJ_RELEASE = oid("conf:project:release")
TARGET_DEBUG = oid("conf:target:debug")
TARGET_RELEASE = oid("conf:target:release")
APP_REF = ref_id(PRODUCT)
XCF_REF = ref_id(XCF_REL)
BRIDGE_REF = ref_id(BRIDGING_REL)
PLIST_REF = ref_id(INFOPLIST_REL)


def q(s: str) -> str:
    """OpenStep plist 中的安全字符串。"""
    if s and all(c.isalnum() or c in "_$./-" for c in s) and not s.startswith("$"):
        return s
    return '"' + s.replace('"', '\\"') + '"'


def main() -> None:
    swift_files = sorted(
        str(p.relative_to(ROOT)) for p in SRC.rglob("*.swift")
    )
    if not swift_files:
        raise SystemExit("没有找到 .swift 源文件")

    groups: dict[str, list[str]] = {}
    for rel in swift_files:
        parts = Path(rel).parts                 # LocalLLMiOS/App/xxx.swift
        group_rel = "/".join(parts[:-1])
        groups.setdefault(group_rel, []).append(rel)

    L: list[str] = []
    a = L.append
    a("// !$*UTF8*$!")
    a("{")
    a("\tarchiveVersion = 1;")
    a("\tclasses = {")
    a("\t};")
    a("\tobjectVersion = 56;")
    a("\tobjects = {")
    a("")

    # ---- PBXBuildFile ----
    a("/* Begin PBXBuildFile section */")
    for rel in swift_files:
        name = Path(rel).name
        a(f"\t\t{build_id(rel)} /* {name} in Sources */ = "
          f"{{isa = PBXBuildFile; fileRef = {ref_id(rel)} /* {name} */; }};")
    a(f"\t\t{build_id(XCF_REL, 'fw')} /* llama.xcframework in Frameworks */ = "
      f"{{isa = PBXBuildFile; fileRef = {XCF_REF} /* llama.xcframework */; }};")
    a(f"\t\t{build_id(XCF_REL, 'embed')} /* llama.xcframework in Embed Frameworks */ = "
      f"{{isa = PBXBuildFile; fileRef = {XCF_REF} /* llama.xcframework */; "
      f"settings = {{ATTRIBUTES = (CodeSignOnCopy, ); }}; }};")
    a("/* End PBXBuildFile section */")
    a("")

    # ---- PBXCopyFilesBuildPhase ----
    a("/* Begin PBXCopyFilesBuildPhase section */")
    a(f"\t\t{EMBED_PHASE} /* Embed Frameworks */ = {{")
    a("\t\t\tisa = PBXCopyFilesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a('\t\t\tdstPath = "";')
    a("\t\t\tdstSubfolderSpec = 10;")
    a("\t\t\tfiles = (")
    a(f"\t\t\t\t{build_id(XCF_REL, 'embed')} /* llama.xcframework in Embed Frameworks */,")
    a("\t\t\t);")
    a('\t\t\tname = "Embed Frameworks";')
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXCopyFilesBuildPhase section */")
    a("")

    # ---- PBXFileReference ----
    a("/* Begin PBXFileReference section */")
    for rel in swift_files:
        name = Path(rel).name
        a(f"\t\t{ref_id(rel)} /* {name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = sourcecode.swift; path = {q(name)}; sourceTree = \"<group>\"; }};")
    a(f"\t\t{BRIDGE_REF} /* Bridging-Header.h */ = {{isa = PBXFileReference; "
      f'lastKnownFileType = sourcecode.c.h; path = {q("Bridging-Header.h")}; sourceTree = "<group>"; }};')
    a(f"\t\t{PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; "
      f'lastKnownFileType = text.plist.xml; path = {q("Info.plist")}; sourceTree = "<group>"; }};')
    a(f"\t\t{XCF_REF} /* llama.xcframework */ = {{isa = PBXFileReference; "
      f'lastKnownFileType = wrapper.xcframework; name = llama.xcframework; '
      f'path = {q(XCF_REL)}; sourceTree = SOURCE_ROOT; }};')
    a(f"\t\t{APP_REF} /* {PRODUCT} */ = {{isa = PBXFileReference; "
      f'explicitFileType = wrapper.application; includeInIndex = 0; '
      f'path = {q(PRODUCT)}; sourceTree = BUILT_PRODUCTS_DIR; }};')
    a("/* End PBXFileReference section */")
    a("")

    # ---- PBXFrameworksBuildPhase ----
    a("/* Begin PBXFrameworksBuildPhase section */")
    a(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{")
    a("\t\t\tisa = PBXFrameworksBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a(f"\t\t\t\t{build_id(XCF_REL, 'fw')} /* llama.xcframework in Frameworks */,")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXFrameworksBuildPhase section */")
    a("")

    # ---- PBXGroup ----
    a("/* Begin PBXGroup section */")
    a(f"\t\t{MAIN_GROUP} = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{group_id('LocalLLMiOS')} /* LocalLLMiOS */,")
    a(f"\t\t\t\t{FRAMEWORKS_GROUP} /* Frameworks */,")
    a(f"\t\t\t\t{PRODUCTS_GROUP} /* Products */,")
    a("\t\t\t);")
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")

    a(f"\t\t{group_id('LocalLLMiOS')} /* LocalLLMiOS */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    for group_rel in sorted(groups):
        a(f"\t\t\t\t{group_id(group_rel)} /* {Path(group_rel).name} */,")
    a("\t\t\t);")
    a('\t\t\tpath = LocalLLMiOS;')
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")

    for group_rel in sorted(groups):
        rels = groups[group_rel]
        a(f"\t\t{group_id(group_rel)} /* {Path(group_rel).name} */ = {{")
        a("\t\t\tisa = PBXGroup;")
        a("\t\t\tchildren = (")
        # App 组里额外挂 plist / bridging header，方便在 Xcode 里点开
        if group_rel.endswith("/App"):
            a(f"\t\t\t\t{PLIST_REF} /* Info.plist */,")
            a(f"\t\t\t\t{BRIDGE_REF} /* Bridging-Header.h */,")
        for rel in rels:
            a(f"\t\t\t\t{ref_id(rel)} /* {Path(rel).name} */,")
        a("\t\t\t);")
        a(f"\t\t\tpath = {q(Path(group_rel).name)};")
        a("\t\t\tsourceTree = \"<group>\";")
        a("\t\t};")

    a(f"\t\t{FRAMEWORKS_GROUP} /* Frameworks */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{XCF_REF} /* llama.xcframework */,")
    a("\t\t\t);")
    a('\t\t\tname = Frameworks;')
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")

    a(f"\t\t{PRODUCTS_GROUP} /* Products */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{APP_REF} /* {PRODUCT} */,")
    a("\t\t\t);")
    a('\t\t\tname = Products;')
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")
    a("/* End PBXGroup section */")
    a("")

    # ---- PBXNativeTarget ----
    a("/* Begin PBXNativeTarget section */")
    a(f"\t\t{TARGET} /* LocalLLMiOS */ = {{")
    a("\t\t\tisa = PBXNativeTarget;")
    a(f"\t\t\tbuildConfigurationList = {TARGET_CONF_LIST} /* Build configuration list for PBXNativeTarget \"LocalLLMiOS\" */;")
    a("\t\t\tbuildPhases = (")
    a(f"\t\t\t\t{SOURCES_PHASE} /* Sources */,")
    a(f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,")
    a(f"\t\t\t\t{EMBED_PHASE} /* Embed Frameworks */,")
    a(f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,")
    a("\t\t\t);")
    a("\t\t\tbuildRules = (")
    a("\t\t\t);")
    a("\t\t\tdependencies = (")
    a("\t\t\t);")
    a("\t\t\tname = LocalLLMiOS;")
    a("\t\t\tproductName = LocalLLMiOS;")
    a(f"\t\t\tproductReference = {APP_REF} /* {PRODUCT} */;")
    a('\t\t\tproductType = "com.apple.product-type.application";')
    a("\t\t};")
    a("/* End PBXNativeTarget section */")
    a("")

    # ---- PBXProject ----
    a("/* Begin PBXProject section */")
    a(f"\t\t{PROJECT} /* Project object */ = {{")
    a("\t\t\tisa = PBXProject;")
    a("\t\t\tattributes = {")
    a("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    a("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    a("\t\t\t\tLastUpgradeCheck = 1600;")
    a(f"\t\t\t\tTargetAttributes = {{ {TARGET} = {{ CreatedOnToolsVersion = 16.0; }}; }};")
    a("\t\t\t};")
    a(f"\t\t\tbuildConfigurationList = {PROJ_CONF_LIST} /* Build configuration list for PBXProject \"LocalLLMiOS\" */;")
    a('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    a("\t\t\tdevelopmentRegion = en;")
    a("\t\t\thasScannedForEncodings = 0;")
    a('\t\t\tknownRegions = (en, Base, "zh-Hans");')
    a(f"\t\t\tmainGroup = {MAIN_GROUP};")
    a(f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;")
    a('\t\t\tprojectDirPath = "";')
    a('\t\t\tprojectRoot = "";')
    a("\t\t\ttargets = (")
    a(f"\t\t\t\t{TARGET} /* LocalLLMiOS */,")
    a("\t\t\t);")
    a("\t\t};")
    a("/* End PBXProject section */")
    a("")

    # ---- PBXResourcesBuildPhase ----
    a("/* Begin PBXResourcesBuildPhase section */")
    a(f"\t\t{RESOURCES_PHASE} /* Resources */ = {{")
    a("\t\t\tisa = PBXResourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXResourcesBuildPhase section */")
    a("")

    # ---- PBXSourcesBuildPhase ----
    a("/* Begin PBXSourcesBuildPhase section */")
    a(f"\t\t{SOURCES_PHASE} /* Sources */ = {{")
    a("\t\t\tisa = PBXSourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    for rel in swift_files:
        a(f"\t\t\t\t{build_id(rel)} /* {Path(rel).name} in Sources */,")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXSourcesBuildPhase section */")
    a("")

    # ---- XCBuildConfiguration ----
    project_common = [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        'CLANG_WARN_DOCUMENTATION_COMMENTS = YES;',
        'ENABLE_STRICT_OBJC_MSGSEND = YES;',
        "IPHONEOS_DEPLOYMENT_TARGET = 16.4;",
        'SDKROOT = iphoneos;',
        "SWIFT_VERSION = 5.0;",
    ]
    target_common = [
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "CODE_SIGN_STYLE = Automatic;",
        "CURRENT_PROJECT_VERSION = 1;",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        f"INFOPLIST_FILE = {INFOPLIST_REL};",
        "IPHONEOS_DEPLOYMENT_TARGET = 16.4;",
        'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");',
        "MARKETING_VERSION = 1.0;",
        'OTHER_LDFLAGS = ("$(inherited)", "-lz", "-lsqlite3", "-lc++", "-ObjC");',
        f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};",
        'PRODUCT_NAME = "$(TARGET_NAME)";',
        'FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "$(PROJECT_DIR)/Vendor/build-apple");',
        'HEADER_SEARCH_PATHS = ("$(inherited)");',
        "SDKROOT = iphoneos;",
        "SUPPORTED_PLATFORMS = iphoneos;",
        f"SWIFT_OBJC_BRIDGING_HEADER = {BRIDGING_REL};",
        "SWIFT_VERSION = 5.0;",
        'TARGETED_DEVICE_FAMILY = "1,2";',
    ]
    a("/* Begin XCBuildConfiguration section */")
    for conf_id, name, lines, extra in [
        (PROJ_DEBUG, "Debug", project_common,
         ['GCC_OPTIMIZATION_LEVEL = 0;', 'SWIFT_OPTIMIZATION_LEVEL = "-Onone";',
          'GCC_PREPROCESSOR_DEFINITIONS = ("DEBUG=1", "$(inherited)");',
          "ONLY_ACTIVE_ARCH = YES;"]),
        (PROJ_RELEASE, "Release", project_common,
         ['SWIFT_OPTIMIZATION_LEVEL = "-O";',
          'SWIFT_COMPILATION_MODE = wholemodule;']),
        (TARGET_DEBUG, "Debug", target_common,
         ['SWIFT_OPTIMIZATION_LEVEL = "-Onone";',
          'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";']),
        (TARGET_RELEASE, "Release", target_common,
         ['SWIFT_OPTIMIZATION_LEVEL = "-O";']),
    ]:
        a(f"\t\t{conf_id} /* {name} */ = {{")
        a("\t\t\tisa = XCBuildConfiguration;")
        a("\t\t\tbuildSettings = {")
        for line in lines + extra:
            a("\t\t\t\t" + line)
        a("\t\t\t};")
        a(f"\t\t\tname = {name};")
        a("\t\t};")
    a("/* End XCBuildConfiguration section */")
    a("")

    # ---- XCConfigurationList ----
    a("/* Begin XCConfigurationList section */")
    for list_id, owner, dbg, rel in [
        (PROJ_CONF_LIST, "PBXProject", PROJ_DEBUG, PROJ_RELEASE),
        (TARGET_CONF_LIST, "PBXNativeTarget", TARGET_DEBUG, TARGET_RELEASE),
    ]:
        a(f"\t\t{list_id} /* Build configuration list for {owner} \"LocalLLMiOS\" */ = {{")
        a("\t\t\tisa = XCConfigurationList;")
        a("\t\t\tbuildConfigurations = (")
        a(f"\t\t\t\t{dbg} /* Debug */,")
        a(f"\t\t\t\t{rel} /* Release */,")
        a("\t\t\t);")
        a("\t\t\tdefaultConfigurationIsVisible = 0;")
        a("\t\t\tdefaultConfigurationName = Release;")
        a("\t\t};")
    a("/* End XCConfigurationList section */")
    a("")
    a("\t};")
    a(f"\trootObject = {PROJECT} /* Project object */;")
    a("}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"已生成 {OUT}")
    print(f"  Swift 源文件: {len(swift_files)} 个")
    print(f"  分组: {', '.join(Path(g).name for g in sorted(groups))}")
    print(f"  XCFramework: {XCF_REL} (Embed & Sign)")


if __name__ == "__main__":
    main()
