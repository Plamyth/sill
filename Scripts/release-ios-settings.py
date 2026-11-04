#!/usr/bin/env python3
"""plutil 객체 그래프로 iPad 릴리스 설정을 읽고 두 빌드 번호만 갱신한다."""

import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def parse(source):
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-"],
        input=source, capture_output=True, check=True,
    )
    return json.loads(result.stdout)


def main():
    path, target_name, bundle, team, key, *change = sys.argv[1:]
    if key not in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        raise ValueError("지원하지 않는 릴리스 설정이다.")
    path = Path(path)
    source = path.read_bytes()
    graph = parse(source)
    objects = graph["objects"]

    def object_of(ref, kind):
        obj = objects[ref]
        if obj["isa"] != kind:
            raise ValueError(f"{ref}의 객체 종류가 {kind}가 아니다.")
        return obj

    def configurations(owner):
        listing = object_of(owner["buildConfigurationList"], "XCConfigurationList")
        configs = {}
        for ref in listing["buildConfigurations"]:
            config = object_of(ref, "XCBuildConfiguration")
            name = config["name"]
            if name in configs or "baseConfigurationReference" in config:
                raise ValueError("중복 설정이나 외부 xcconfig는 해석할 수 없다.")
            configs[name] = (ref, config["buildSettings"])
        return configs

    project = object_of(graph["rootObject"], "PBXProject")
    targets = [object_of(ref, "PBXNativeTarget") for ref in project["targets"]]
    matches = [target for target in targets if target.get("name") == target_name]
    if len(matches) != 1:
        raise ValueError(f"{target_name} 타깃이 하나로 확정되지 않는다.")
    target = matches[0]
    if target.get("productType") != "com.apple.product-type.application":
        raise ValueError("릴리스 타깃이 앱이 아니다.")
    configs = configurations(target)
    if set(configs) != {"Debug", "Release"}:
        raise ValueError("Sill에는 Debug와 Release 설정 두 개가 필요하다.")
    project_configs = configurations(project)
    refs = {ref for ref, _ in configs.values()}
    if refs & {ref for ref, _ in project_configs.values()}:
        raise ValueError("Sill과 프로젝트가 설정 객체를 공유한다.")
    for other in targets:
        if other is target:
            continue
        for ref, settings in configurations(other).values():
            duplicate_bundle = any(value == bundle for key, value in settings.items()
                                   if key == "PRODUCT_BUNDLE_IDENTIFIER" or key.startswith("PRODUCT_BUNDLE_IDENTIFIER["))
            if ref in refs or duplicate_bundle:
                raise ValueError("다른 타깃과 Sill의 설정 또는 bundle ID가 중복된다.")

    values = []
    for name, (_, settings) in configs.items():
        inherited = project_configs[name][1]
        for setting in ("PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", key):
            if any(k.startswith(setting + "[") for k in (*settings, *inherited)):
                raise ValueError(f"{name}의 조건부 {setting}은 확정할 수 없다.")
        if settings.get("PRODUCT_BUNDLE_IDENTIFIER") != bundle:
            raise ValueError(f"{name}의 bundle ID가 승인된 iPad 앱과 다르다.")
        if settings.get("DEVELOPMENT_TEAM", inherited.get("DEVELOPMENT_TEAM")) != team:
            raise ValueError(f"{name}의 서명 팀이 승인된 팀과 다르다.")
        value = settings.get(key)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
            raise ValueError(f"{name}의 {key}가 명시된 버전 숫자가 아니다.")
        values.append(value)
    if len(set(values)) != 1:
        raise ValueError(f"Sill Debug/Release의 {key}가 다르다.")
    if not change:
        print(values[0])
        return
    if key != "CURRENT_PROJECT_VERSION" or len(change) != 2:
        raise ValueError("빌드 번호만 갱신할 수 있다.")
    old, new = change
    if values[0] != old or not old.isdecimal() or str(int(old) + 1) != new:
        raise ValueError("확인한 현재 빌드 번호의 다음 정수만 허용한다.")

    # 객체는 plutil로 선택한다. 원문에서는 해당 객체의 숫자만 바꿔 주석·서식을 보존한다.
    expected = copy.deepcopy(graph)
    text = source.decode("utf-8")
    for ref in refs:
        block = re.compile(
            rf"(?ms)^([ \t]*){re.escape(ref)}(?:[ \t]+/\*[^\n]*\*/)?[ \t]*=[ \t]*\{{.*?^\1\}};[ \t]*$"
        )
        matches = list(block.finditer(text))
        if len(matches) != 1:
            raise ValueError("설정 객체의 원문 위치가 하나로 확정되지 않는다.")
        match = matches[0]
        updated, count = re.subn(
            rf'(?m)^([ \t]*CURRENT_PROJECT_VERSION[ \t]*=[ \t]*)"?{re.escape(old)}"?(;[ \t]*)$',
            rf"\g<1>{new}\2", match.group(),
        )
        if count != 1:
            raise ValueError("설정 객체 안의 빌드 번호가 하나로 확정되지 않는다.")
        text = text[:match.start()] + updated + text[match.end():]
        expected["objects"][ref]["buildSettings"][key] = new
    output = text.encode("utf-8")
    if parse(output) != expected:
        raise ValueError("두 빌드 번호 외에 객체 그래프가 바뀌어 갱신을 거부한다.")
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".release-ios-", delete=False) as pending:
        temporary = Path(pending.name)
        try:
            os.fchmod(pending.fileno(), path.stat().st_mode)
            pending.write(output)
            pending.flush()
            if path.read_bytes() != source:
                raise ValueError("읽은 뒤 프로젝트가 바뀌어 현재 변경을 보존한다.")
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"오류: iPad 릴리스 설정을 확정할 수 없다: {error}", file=sys.stderr)
        sys.exit(1)
