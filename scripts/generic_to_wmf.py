#!/usr/bin/env python3
"""
generic_to_wmf.py — Deterministic generic→WMF Dockerfile.template transform.

Consumes a generic Dockerfile whose version values come from versions.env
(passed pre-expanded), and applies the fixed set of WMF deltas:

  D1 base image      debian:bookworm-* -> docker-registry.wikimedia.org/amd-pytorch-common:<tag>
  D2 apt source      repo.radeon.com block -> apt.wikimedia.org mirror one-liner
  D3 proxy env       inject http_proxy ARG+ENV after each stage FROM (builder/runtime)
  D4 chown           COPY --from=X -> COPY --from=X --chown=somebody
  D5 user            insert `USER somebody` before the runtime wheel pip install
  D6 render group    drop APT_PREF pin (mirror handles pinning); keep groupadd
  D7 build-deps      drop the AITER build-deps continuation in the runtime apt line
                     (amd-pytorch-common already provides them)
  D8 strip comments  WMF template omits the explanatory # comment lines
  header             swap banner; 4GB -> 12GB note

The correctness oracle is wmf/vllm014/Dockerfile.template — see selftest.
"""
import sys, re

def transform(generic_lines, wmf_base_tag, rocm_apt_suffix):
    out = []
    lines = generic_lines

    # --- header banner -----------------------------------------------------
    out += [
        "########################################################################",
        "# wmf-debian-vllm: ROCm, PyTorch, MoRi, FlashAttention, aiter, vLLM    #",
        "#                                                                      #",
        "# Note: Multiple RUN commands are intentionally kept separate to avoid #",
        "# hitting the 12GB (compressed) Docker layer limit required by the     #",
        "# Wikimedia Docker registry.                                           #",
        "########################################################################",
        "",
    ]

    i = 0
    n = len(lines)
    cur_stage = None  # track which stage we are emitting into
    # skip the generic header comment block + the global ARG block
    while i < n and (lines[i].startswith("#") or lines[i].strip() == ""):
        i += 1
    # skip global ARG declarations (the version block before first FROM)
    while i < n and lines[i].startswith("ARG "):
        i += 1
        while i < n and lines[i].strip() == "":
            i += 1

    def is_comment(l): return l.lstrip().startswith("#")

    while i < n:
        line = lines[i]

        # D1+D3: stage FROM. Two kinds:
        #   FROM <base> AS builder|runtime -> swap base + inject proxy
        #   FROM builder AS <intermediate> -> keep verbatim (inherits builder)
        m = re.match(r'^FROM\s+(\S+)\s+[Aa][Ss]\s+(\S+)', line)
        if m:
            src_img, stage = m.group(1), m.group(2)
            cur_stage = stage
            if stage in ("builder", "runtime"):
                out.append(f"FROM docker-registry.wikimedia.org/amd-pytorch-common:{wmf_base_tag} as {stage}")
                out.append("")
                out.append("# Set proxy env vars required on ml-lab1002")
                out.append("ARG http_proxy")
                out.append("ENV http_proxy=${http_proxy}")
                out.append("ENV https_proxy=${http_proxy}")
                out.append("ENV HTTP_PROXY=${http_proxy}")
                out.append("ENV HTTPS_PROXY=${http_proxy}")
                out.append("")
            else:
                out.append(f"FROM {src_img} AS {stage}")
            i += 1
            continue

        # drop stage-local ARG re-declarations and version ARGs, BUT keep
        # structural path ARGs the COPY lines depend on (TORCH_LIB_PATH).
        if re.match(r'^ARG\s+TORCH_LIB_PATH=', line):
            out.append(line)
            i += 1
            continue
        if re.match(r'^ARG\s+[A-Z_]', line):
            i += 1
            continue

        # D6: drop APT_PREF pin line + its groupadd printf continuation; keep groupadd
        if 'APT_PREF=' in line:
            i += 1
            continue
        if re.match(r'^RUN groupadd -g 109 render', line):
            # builder keeps a single-line groupadd; runtime drops it (base image
            # already has the render group). Drop the "&& printf APT_PREF" cont.
            nxt_is_printf = (i + 1 < n and 'printf "$APT_PREF"' in lines[i + 1])
            if cur_stage == "runtime":
                i += 1
                if nxt_is_printf:
                    i += 1
                continue
            out.append("# Mirror upstream: create 'render' group")
            out.append("RUN groupadd -g 109 render")
            i += 1
            if nxt_is_printf:
                i += 1
            continue

        # runtime: drop the bare `ARG TORCH_LIB_PATH=...` line (inlined by base)
        if cur_stage == "runtime" and re.match(r'^ARG\s+TORCH_LIB_PATH=', line):
            i += 1
            continue

        # D2/D7: the AMD repo + install block -> WMF mirror one-liner
        if 'mkdir -p /etc/apt/keyrings' in line:
            # collect the whole RUN block (until a line without trailing backslash)
            block = [line]
            j = i
            while lines[j].rstrip().endswith("\\"):
                j += 1
                block.append(lines[j])
            # decide builder vs runtime install set by scanning the block
            blocktext = "\n".join(block)
            # extract the package list line(s): the ones after 'apt-get install -q -y \'
            # builder list contains 'hsa-rocr-dev'; runtime list contains 'rocm-smi-lib hip-dev'
            is_runtime = 'rocm-smi-lib hip-dev' in blocktext
            # find the primary package line (first install list not --no-install-recommends)
            pkg_lines = []
            capture = False
            for b in block:
                if re.search(r'apt-get install -q -y\s*\\?\s*$', b) and '--no-install-recommends' not in b:
                    capture = True
                    continue
                if capture:
                    if b.strip().startswith('&& apt-get') or b.strip().startswith('&& rm') or b.strip().startswith('&& apt-get purge'):
                        capture = False
                        continue
                    pkg_lines.append(b.strip().rstrip("\\").strip())
            if is_runtime:
                # D7: keep only the FIRST package line (common deps); drop build-deps continuation
                pkgs = pkg_lines[0] if pkg_lines else ""
                out.append("# Add Wikimedia ROCm 7.0 mirror then install minimal runtime ROCm libs and Python tooling")
                out.append(f'RUN echo "deb http://apt.wikimedia.org/wikimedia bookworm-wikimedia thirdparty/amd-rocm{rocm_apt_suffix}" > /etc/apt/sources.list.d/rocm.list \\')
                out.append("    && apt-get update -q \\")
                out.append(f"    && apt-get install -q -y {pkgs} \\")
                out.append("    && apt-get clean \\")
                out.append("    && rm -rf /var/lib/apt/lists/*")
            else:
                pkgs = " ".join(pkg_lines)
                out.append("# Add Wikimedia ROCm 7.0 mirror then install ROCm libs and Python tooling")
                out.append(f'RUN echo "deb http://apt.wikimedia.org/wikimedia bookworm-wikimedia thirdparty/amd-rocm{rocm_apt_suffix}" > /etc/apt/sources.list.d/rocm.list \\')
                out.append("    && apt-get update -q \\")
                out.append(f"    && apt-get install -q -y {pkgs}")
            i = j + 1
            continue

        # D4: add --chown=somebody to COPY --from lines
        cm = re.match(r'^COPY\s+--from=(\S+)\s+(.*)$', line)
        if cm and '--chown=' not in line:
            out.append(f"COPY --from={cm.group(1)} --chown=somebody {cm.group(2)}")
            i += 1
            continue

        # D5: insert USER somebody before the runtime wheel install
        if re.match(r'^RUN pip install --no-cache-dir /srv/wheels/\*\.whl', line):
            out.append("# Switch to user \"somebody\" to avoid running the container as root")
            out.append("USER somebody")
            out.append("")
            out.append(line)
            i += 1
            continue

        # WMF keeps section comments — pass them through unchanged.

        out.append(line)
        i += 1

    # collapse 3+ blank lines to max 1, strip trailing blanks
    cleaned = []
    blank = 0
    for l in out:
        if l.strip() == "":
            blank += 1
            if blank > 1:
                continue
        else:
            blank = 0
        cleaned.append(l)
    while cleaned and cleaned[-1].strip() == "":
        cleaned.pop()
    return cleaned


if __name__ == "__main__":
    src, wmf_tag, suffix = sys.argv[1], sys.argv[2], sys.argv[3]
    lines = open(src).read().split("\n")
    result = transform(lines, wmf_tag, suffix)
    sys.stdout.write("\n".join(result) + "\n")
