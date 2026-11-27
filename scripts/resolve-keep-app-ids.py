#!/usr/bin/env python3
"""
resolve-keep-app-ids.py — Compute the BC_KEEP_APP_IDS set for a consumer
project so the BC container can selectively uninstall stock extensions
the project does NOT depend on, dramatically improving startup time.

Inputs:
  --app-json <path>     Path to a consumer app.json (may be repeated)
  --app-file <path>     Path to a consumer .app file (may be repeated)
  --artifact-dir <path> BC artifact root that contains stock extensions
                         (e.g. .../artifact-cache/27.5)
  --extra-ids <list>    Comma-separated GUIDs to always include on top
                         of the baseline + dependency closure (optional)
  --extra-app-name <n>  Name of an artifact app to keep, with its own
                         dependencies (may be repeated). For apps that a
                         Windows container has installed but no consumer
                         declares, e.g. Tests-TestLibraries (issue #125).

Output:
  Comma-separated lowercase GUIDs to stdout — feed straight into
  BC_KEEP_APP_IDS for `BC_CLEAR_ALL_APPS=selective`.

Logic:
  baseline ∪ extras ∪ transitive_closure(consumer_immediate_deps,
                                          available_artifact_apps)

The baseline is ALWAYS included, even if --app-json / --app-file are
empty or fail to parse, so the container can never accidentally clear
an app the project might secretly depend on. The five baseline apps
(System, System Application, Business Foundation, Base Application,
Application umbrella) are stable across BC versions per Microsoft
convention.
"""

import argparse
import io
import json
import os
import re
import sys
import zipfile
from pathlib import Path

# Make sibling helpers importable when invoked as `python3 .../resolve-keep-app-ids.py`
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bcapp import is_platform_copy  # noqa: E402

# ── Baseline (always kept) ────────────────────────────────────────────────
# Stable across BC versions. Including any of these in BC_KEEP_APP_IDS is
# harmless even if the app is not actually published in this BC build —
# the entrypoint's keep filter just won't match it.
#
# Includes ONLY the application stack (System / System Application /
# Business Foundation / Base Application / Application umbrella). The test
# framework apps are NOT in the baseline because they're handled separately
# by the entrypoint's "Publishing test framework" step (entrypoint.sh:864),
# which deletes them via SQL filter and then does a fresh install via the
# dev endpoint after NST starts. If we kept them in the SQL filter, the
# republish step would see them as "already deployed" (HTTP 422) and
# skip the install — leaving them in a published-but-not-installed-for-
# tenant-default state which then breaks the consumer's test app publish
# with "Library Assert ... is not installed" cryptic errors.
BASELINE = {
    "8874ed3a-0643-4247-9ced-7a7002f7135d",  # System (AL platform symbols)
    "63ca2fa4-4f03-4f2b-a480-172fef340d3f",  # System Application
    # Business Foundation, Base Application, and Application umbrella are NOT
    # hardcoded here — they are included only when the consumer's transitive
    # dependency closure requires them. This lets platform-only extensions run
    # without the full application stack installed for tenant.
    # "f3552374-a1f2-4356-848e-196002525837",  # Business Foundation
    # "437dbf0e-84ff-417a-965d-ed2bb9650972",  # Base Application
    # "c1335042-3002-4257-bf8a-75c898ccb1b8",  # Application umbrella
}

# ── Test framework apps (kept in the closure when consumers depend on them) ──
#
# Historical note: this set used to be deliberately EXCLUDED from the
# transitive closure, on the theory that the entrypoint's
# "Publishing test framework" republish step would freshly install them
# after NST starts. That republish step was a hand-curated array which
# we kept patching every time a consumer hit a missing dep — and the
# discovery loop was painful (silent install failures, "0 tests ran"
# with no clue, multiple cycles of "find missing dep, add to array,
# rebuild image, retry").
#
# The right architecture is to never wipe them in the first place. The
# selective filter now keeps everything in the consumer's transitive
# closure, including any test framework apps the consumer reaches via
# its dependency chain. The entrypoint no longer needs to republish
# anything from this set.
TEST_FRAMEWORK_IDS: set[str] = set()  # intentionally empty — see comment above


# ── .app file reader ──────────────────────────────────────────────────────
# Supports regular .app files (NavxManifest.xml at root), R2R packages
# (readytorunappmanifest.json + nested .app), and rare app.json fallback.
# Adapted from sort-apps-by-deps.py.

def _xml_attr(xml: str, attr: str) -> str | None:
    m = re.search(rf'{attr}\s*=\s*"([^"]*)"', xml, re.IGNORECASE)
    return m.group(1) if m else None


def _read_inner_app(data: bytes) -> dict | None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as inner_z:
            if "NavxManifest.xml" in inner_z.namelist():
                xml = inner_z.read("NavxManifest.xml").decode("utf-8", errors="replace")
                deps = []
                for m in re.finditer(
                    r"<Dependency[^>]*?/>|<Dependency[^>]*?>.*?</Dependency>",
                    xml, re.DOTALL,
                ):
                    dep_xml = m.group(0)
                    dep_id = (_xml_attr(dep_xml, "AppId") or _xml_attr(dep_xml, "Id") or "")
                    if dep_id:
                        deps.append({"id": dep_id.lower()})
                return {"dependencies": deps}
    except Exception:
        pass
    return None


def read_app_info(app_path: str) -> dict | None:
    try:
        with zipfile.ZipFile(app_path) as z:
            names = z.namelist()

            if "readytorunappmanifest.json" in names:
                manifest = json.loads(z.read("readytorunappmanifest.json"))
                app_id = manifest.get("EmbeddedAppId", "").lower()
                deps = []
                for dep in manifest.get("Dependencies", []):
                    dep_id = (dep.get("AppId") or dep.get("Id") or "").lower()
                    if dep_id:
                        deps.append({"id": dep_id})
                if not deps:
                    nested = manifest.get("EmbeddedAppFileName", "")
                    if nested and nested in names:
                        try:
                            inner = _read_inner_app(z.read(nested))
                            if inner:
                                deps = inner.get("dependencies", [])
                        except Exception:
                            pass
                return {"id": app_id, "name": manifest.get("EmbeddedAppName", ""),
                        "dependencies": deps, "path": app_path}

            if "NavxManifest.xml" in names:
                xml = z.read("NavxManifest.xml").decode("utf-8", errors="replace")
                app_id = (_xml_attr(xml, "Id") or _xml_attr(xml, "AppId") or "").lower()
                deps = []
                for m in re.finditer(
                    r"<Dependency[^>]*?/>|<Dependency[^>]*?>.*?</Dependency>",
                    xml, re.DOTALL,
                ):
                    dep_xml = m.group(0)
                    dep_id = (_xml_attr(dep_xml, "AppId") or _xml_attr(dep_xml, "Id") or "")
                    if dep_id:
                        deps.append({"id": dep_id.lower()})
                return {"id": app_id, "name": _xml_attr(xml, "Name") or "",
                        "dependencies": deps, "path": app_path}

            if "app.json" in names:
                data = json.loads(z.read("app.json").decode("utf-8-sig"))
                deps = []
                for dep in data.get("dependencies", []):
                    dep_id = (dep.get("id") or dep.get("appId") or "").lower()
                    if dep_id:
                        deps.append({"id": dep_id})
                return {
                    "id": (data.get("id") or "").lower(),
                    "name": data.get("name") or "",
                    "dependencies": deps,
                    "path": app_path,
                }
    except Exception as e:
        print(f"WARN: cannot read {app_path}: {e}", file=sys.stderr)
    return None


# ── Resolver ──────────────────────────────────────────────────────────────

def parse_id_list(s: str) -> set[str]:
    return {x.strip().lower() for x in s.split(",") if x.strip()}


def load_artifact_apps(artifact_dir: str) -> dict:
    apps = {}
    for root, _, files in os.walk(artifact_dir):
        for f in files:
            if not f.endswith(".app"):
                continue
            info = read_app_info(os.path.join(root, f))
            if info and info.get("id"):
                # First write wins, except that a country artifact copy replaces
                # a platform (W1) copy: their dependencies can differ.
                existing = apps.setdefault(info["id"], info)
                if (is_platform_copy(existing["path"], artifact_dir)
                        and not is_platform_copy(info["path"], artifact_dir)):
                    apps[info["id"]] = info
    return apps



# ── Shorthand property → GUID mappings ───────────────────────────────────────
# The app.json "platform" and "application" version properties are shorthand
# for Microsoft's well-known app IDs. When a consumer declares these, we treat
# them as explicit seeds so the transitive closure includes them (and their
# dependents) in BC_KEEP_APP_IDS.
#   platform    → System
#   application → System Application + Business Foundation + Base Application
#                 + Application umbrella
# System Application is always in the BASELINE so it doesn't need to be here,
# but listing it keeps the mapping self-documenting.
PLATFORM_IDS = {
    "8874ed3a-0643-4247-9ced-7a7002f7135d",  # System
}
APPLICATION_IDS = {
    "63ca2fa4-4f03-4f2b-a480-172fef340d3f",  # System Application
    "f3552374-a1f2-4356-848e-196002525837",  # Business Foundation
    "437dbf0e-84ff-417a-965d-ed2bb9650972",  # Base Application
    "c1335042-3002-4257-bf8a-75c898ccb1b8",  # Application umbrella
}


def read_consumer_seeds(app_json_paths, app_file_paths) -> set[str]:
    """Return the set of immediate dependency GUIDs declared by the consumer."""
    seeds = set()
    for p in app_json_paths:
        try:
            data = json.loads(Path(p).read_text(encoding="utf-8-sig"))
            for dep in data.get("dependencies", []):
                dep_id = (dep.get("id") or dep.get("appId") or "").lower()
                if dep_id:
                    seeds.add(dep_id)
            # Expand shorthand properties into their well-known GUIDs.
            if data.get("platform"):
                seeds |= PLATFORM_IDS
            if data.get("application"):
                seeds |= APPLICATION_IDS
        except Exception as e:
            print(f"WARN: cannot read {p}: {e}", file=sys.stderr)
    for p in app_file_paths:
        info = read_app_info(p)
        if info:
            for dep in info.get("dependencies", []):
                seeds.add(dep["id"])
    return seeds


def declares_application(info: dict) -> bool:
    """True when the app's NavxManifest has a non-empty Application attribute.

    Read on demand, only for apps in the closure: an R2R package keeps the
    manifest in a nested .app, and opening that for every artifact app would
    make load_artifact_apps much slower for no gain.
    """
    path = info.get("path")
    if not path:
        return False
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            if "NavxManifest.xml" not in names:
                inner = [n for n in names if n.endswith(".app")]
                if not inner:
                    return False
                z = zipfile.ZipFile(io.BytesIO(z.read(inner[0])))
                names = z.namelist()
                if "NavxManifest.xml" not in names:
                    return False
            xml = z.read("NavxManifest.xml").decode("utf-8", errors="replace")
    except Exception:
        return False
    app_tag = re.search(r"<App\s[^>]*>", xml)
    return bool(app_tag and _xml_attr(app_tag.group(0), "Application"))


def walk_closure(seed_ids: set[str], apps: dict) -> set[str]:
    """Walk the transitive dependency closure starting from seed_ids.

    Includes EVERYTHING the consumer transitively depends on, test
    framework apps included. The selective filter then preserves
    everything in this closure, so the entrypoint never has to
    republish test framework apps after the fact.
    """
    out = set()

    def visit(aid: str):
        if aid in out:
            return
        if aid not in apps:
            return  # not in this BC build — skip
        out.add(aid)
        for dep in apps[aid].get("dependencies", []):
            visit(dep["id"])
        # An artifact app's manifest can say Application="x" instead of
        # listing Base Application as a dependency, the same shorthand as
        # app.json's "application". Tests-TestLibraries and Data Archive both
        # do. Without this, Base Application falls out of the closure and the
        # selective filter removes it from under them.
        if declares_application(apps[aid]):
            for app_id in APPLICATION_IDS:
                visit(app_id)

    for sid in seed_ids:
        visit(sid)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app-json", action="append", default=[],
                        help="Path to a consumer app.json (repeatable)")
    parser.add_argument("--app-file", action="append", default=[],
                        help="Path to a consumer .app file (repeatable)")
    parser.add_argument("--artifact-dir", required=True,
                        help="BC artifact root (e.g. artifact-cache/27.5)")
    parser.add_argument("--extra-ids", default="",
                        help="Comma-separated extra GUIDs to always include")
    parser.add_argument("--extra-app-name", action="append", default=[],
                        help="Name of an artifact app to keep together with "
                             "its dependencies (repeatable, case-insensitive)")
    parser.add_argument("--no-test-runner-seed", action="store_true",
                        help="Don't auto-seed bc-linux's TestRunnerExtension "
                             "app.json into the closure (see below). Only use "
                             "this if the entrypoint won't publish it.")
    args = parser.parse_args()

    # Auto-seed bc-linux's own TestRunnerExtension app.json.
    #
    # The entrypoint ALWAYS publishes /bc/testrunner/TestRunner.app, and that
    # extension depends on Microsoft's Test Runner. Consumer test apps
    # generally do NOT declare Test Runner — they declare Library Assert and
    # Tests-TestLibraries. So without this seed Test Runner falls outside the
    # closure, the selective filter deletes it in SQL, and the entrypoint's
    # own publish then fails AL1024, taking test execution down with it.
    #
    # This used to be every caller's job. The two reusable workflows passed
    # it; all four inlined example pipelines did not, so anyone who copied an
    # example instead of calling the reusable workflow had a broken test run
    # and an error message pointing nowhere near the cause. Seeding here
    # rather than at the call site means the fix reaches those consumers too
    # — they check bc-linux out at run time, so they get this script.
    #
    # Callers may still pass the same --app-json explicitly; the seed is a
    # set union, so it's idempotent.
    if not args.no_test_runner_seed:
        tre = Path(__file__).resolve().parent.parent / "extensions" / "TestRunnerExtension" / "app.json"
        if tre.is_file():
            if str(tre) not in args.app_json:
                args.app_json = list(args.app_json) + [str(tre)]
        else:
            print(f"WARN: TestRunnerExtension app.json not found at {tre} — "
                  f"Test Runner may be missing from the keep set",
                  file=sys.stderr)

    keep = set(BASELINE)
    extras = parse_id_list(args.extra_ids)
    if extras:
        keep |= extras
        print(f"+ extras: {len(extras)}", file=sys.stderr)

    seeds = read_consumer_seeds(args.app_json, args.app_file)
    print(f"consumer seeds: {len(seeds)}", file=sys.stderr)

    # Apps named with --extra-app-name are seeds like a declared dependency,
    # so their own dependencies are kept too. A name that matches no app in
    # this artifact is an error: silently dropping it would give a tier that
    # differs from what the caller asked for, with nothing saying so.
    extra_names = [n.strip() for n in args.extra_app_name if n.strip()]
    artifact_apps = None
    if extra_names:
        artifact_apps = load_artifact_apps(args.artifact_dir)
        for name in extra_names:
            ids = {aid for aid, info in artifact_apps.items()
                   if (info.get("name") or "").lower() == name.lower()}
            if not ids:
                print(f"ERROR: --extra-app-name '{name}' matches no app in "
                      f"{args.artifact_dir}", file=sys.stderr)
                sys.exit(1)
            print(f"+ extra app '{name}': {sorted(ids)}", file=sys.stderr)
            seeds |= ids

    if seeds:
        if artifact_apps is None:
            artifact_apps = load_artifact_apps(args.artifact_dir)
        print(f"artifact apps loaded: {len(artifact_apps)}", file=sys.stderr)
        closure = walk_closure(seeds, artifact_apps)
        print(f"transitive closure: {len(closure)}", file=sys.stderr)

        # Anything in seeds but not in closure is genuinely missing from
        # the artifact set — likely pre-installed in BC's database (System
        # Application, Business Foundation, etc.) and resolved at install
        # time without needing to be in the keep set.
        unresolved = seeds - closure
        if unresolved:
            print(f"WARN: {len(unresolved)} consumer dep(s) not found in artifact "
                  f"set (will rely on baseline): {sorted(unresolved)}", file=sys.stderr)
        keep |= closure

    closure_added = len(keep - BASELINE - extras) if seeds else 0
    print(f"final keep set: {len(keep)} apps "
          f"(baseline={len(BASELINE)}, "
          f"closure_added={closure_added}, "
          f"extras={len(extras)})", file=sys.stderr)

    # Output: comma-separated lowercase GUIDs, sorted for determinism.
    print(",".join(sorted(keep)))


if __name__ == "__main__":
    main()
