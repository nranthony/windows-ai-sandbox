from __future__ import annotations

import os

import streamlit as st

from lib.config_io import ConfigIO
from lib.docker_client import DockerClient
from lib.proxy_categories import (
    CATEGORY_ORDER,
    CATEGORY_SLUGS,
    category_for,
    color_var,
    css_vars_block,
)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


def _pill(text: str, color: str) -> str:
    return (
        f'<span style="background:{color}; color:white; padding:2px 10px; '
        f'border-radius:10px; font-size:0.78em; font-weight:600; '
        f'letter-spacing:0.03em; white-space:nowrap;">{text}</span>'
    )


def PILL_ON(n):    return _pill(f"ON · {n}", "#16a34a")
def PILL_PARTIAL(n, total): return _pill(f"{n}/{total} ON", "#d97706")
PILL_OFF = _pill("OFF", "#71717a")


# --- Callbacks --------------------------------------------------------------

def _on_dom_toggle(tag: str, domain: str) -> None:
    new_val = st.session_state[f"dom_{tag}_{domain}"]
    for e in st.session_state.entries:
        if e.block_tag == tag and e.domain == domain:
            e.is_commented = not new_val
            return


def _drop_dom_keys() -> None:
    for k in [k for k in st.session_state.keys() if k.startswith("dom_")]:
        del st.session_state[k]


def _on_block_all(tag: str, enable: bool) -> None:
    for e in st.session_state.entries:
        if e.block_tag == tag and e.domain:
            e.is_commented = not enable
    _drop_dom_keys()


def _on_refresh(config_io: ConfigIO) -> None:
    st.session_state.entries = config_io.read_allowed_domains()
    _drop_dom_keys()


def _toggle_category(slug: str) -> None:
    key = f"cat_open_{slug}"
    st.session_state[key] = not st.session_state.get(key, True)


def _set_all_categories(is_open: bool) -> None:
    for slug in CATEGORY_SLUGS.values():
        st.session_state[f"cat_open_{slug}"] = is_open


def _render_block_row(tag: str, block_entries: list) -> None:
    enabled_count = sum(1 for e in block_entries if not e.is_commented)
    total_count = len(block_entries)

    if enabled_count == 0:
        pill = PILL_OFF
    elif enabled_count == total_count:
        pill = PILL_ON(total_count)
    else:
        pill = PILL_PARTIAL(enabled_count, total_count)

    accent, name_col, pill_col, dom_col, on_col, off_col = st.columns(
        [0.25, 3, 1.4, 1.7, 0.9, 0.9], vertical_alignment="center",
    )
    accent.markdown(
        f'<div style="width:5px; height:1.6em; border-radius:3px; '
        f'background:{color_var(tag)};"></div>',
        unsafe_allow_html=True,
    )
    name_col.markdown(f"**{tag}**")
    pill_col.markdown(pill, unsafe_allow_html=True)

    with dom_col.popover(f"Domains ({total_count})", width="stretch"):
        for e in block_entries:
            label = e.domain if not e.is_commented else f":gray[~~{e.domain}~~]"
            st.checkbox(
                label,
                value=not e.is_commented,
                key=f"dom_{tag}_{e.domain}",
                on_change=_on_dom_toggle,
                args=(tag, e.domain),
            )

    on_col.button(
        "All on", key=f"on_{tag}", width="stretch",
        on_click=_on_block_all, args=(tag, True),
    )
    off_col.button(
        "All off", key=f"off_{tag}", width="stretch",
        on_click=_on_block_all, args=(tag, False),
    )


def render() -> None:
    config_io = ConfigIO(REPO_ROOT)
    docker_client = DockerClient()

    st.markdown(css_vars_block(), unsafe_allow_html=True)

    hdr_l, hdr_r = st.columns([3, 2])
    with hdr_l:
        st.markdown("Manage domains in `proxy/allowed_domains.txt` and reload squid.")

    _running = docker_client.get_running_profiles()
    with hdr_l:
        if docker_client.client is None:
            st.warning(
                "Docker daemon not reachable. File edits will save, but no "
                "proxies can be reloaded. Is rootless Docker running?"
            )
        elif not _running:
            st.info(
                "No profiles running. File edits save to disk and take effect "
                "when a profile is next started — squid reads the allowlist "
                "fresh on container startup."
            )
        else:
            st.caption(f"Profiles up: **{', '.join(sorted(_running))}** — "
                       f"reload will hit each one.")

    # --- Hydration ----------------------------------------------------------

    if 'entries' not in st.session_state:
        st.session_state.entries = config_io.read_allowed_domains()

    entries = st.session_state.entries

    blocks: dict[str, list] = {}
    for entry in entries:
        if entry.block_tag:
            if entry.block_tag not in blocks:
                blocks[entry.block_tag] = []
            if entry.domain:
                blocks[entry.block_tag].append(entry)

    # --- Actions --------------------------------------------------------------

    with hdr_r:
        st.markdown("#### Actions")
        bcol1, bcol2 = st.columns(2)
        save_clicked = bcol1.button("Save & Reload Proxies", type="primary",
                                    width="stretch")
        bcol2.button("Refresh from File", on_click=_on_refresh, args=(config_io,),
                     width="stretch")
        action_status = st.container()

    if save_clicked:
        with st.spinner("Saving allowlist and reloading proxies..."):
            config_io.write_allowed_domains(st.session_state.entries)
            st.session_state["last_reload_results"] = (
                docker_client.reload_all_proxies()
                if docker_client.client is not None else []
            )
            st.session_state["last_reload_no_docker"] = docker_client.client is None
        st.toast("Saved to proxy/allowed_domains.txt", icon="\U0001f4be")
        st.session_state.entries = config_io.read_allowed_domains()
        _drop_dom_keys()
        st.rerun()

    if "last_reload_results" in st.session_state:
        with action_status:
            if st.session_state.get("last_reload_no_docker"):
                st.info("File saved. Docker daemon not reachable — no proxies "
                        "to reload now.")
            else:
                results = st.session_state["last_reload_results"]
                if not results:
                    st.info("File saved. No running egress-proxy containers — "
                            "the new allowlist will load on next "
                            "`scripts/profile.sh <p> up`.")
                else:
                    ok = [r for r in results if r["ok"]]
                    failed = [r for r in results if not r["ok"]]
                    if ok:
                        parts = [
                            f"{r['profile']} ({r['domains']} domains)"
                            if r.get("domains") is not None else r["profile"]
                            for r in ok
                        ]
                        st.success(f"Reloaded (restarted): {', '.join(parts)}")
                    for r in failed:
                        if r.get("needs_recreate"):
                            st.error(f"**{r['profile']}**: {r['msg']}")
                            if st.button(
                                f"Recreate egress-proxy-{r['profile']}",
                                key=f"recreate_{r['profile']}",
                                type="primary",
                            ):
                                with st.spinner(
                                    f"Recreating egress-proxy-{r['profile']}..."
                                ):
                                    rc = docker_client.recreate_proxy(r["profile"])
                                if rc["ok"]:
                                    st.session_state["last_reload_results"] = (
                                        docker_client.reload_all_proxies()
                                    )
                                    st.toast(
                                        f"egress-proxy-{r['profile']} recreated",
                                        icon="✅",
                                    )
                                    st.rerun()
                                else:
                                    st.error(f"Recreate failed: {rc['msg']}")
                        else:
                            st.error(f"{r['profile']}: {r['msg']}")

    # --- Blocks (single column, grouped by category) -------------------------

    bh_l, bh_r = st.columns([1, 2])
    bh_l.subheader("Blocks")
    _legend_html = (
        f'<div style="text-align:right; padding-top:0.6em; font-size:0.85em; '
        f'color:#52525b;">'
        f'{_pill("ON", "#16a34a")} all enabled &nbsp;·&nbsp; '
        f'{_pill("PARTIAL", "#d97706")} some enabled &nbsp;·&nbsp; '
        f'{_pill("OFF", "#71717a")} all commented out'
        f'</div>'
    )
    bh_r.markdown(_legend_html, unsafe_allow_html=True)

    search_col, expand_col, collapse_col = st.columns(
        [4, 1, 1], vertical_alignment="bottom",
    )
    query = search_col.text_input(
        "Search sections",
        placeholder="Filter by tag, domain, or category…",
        key="block_search",
    ).strip().lower()
    expand_col.button("Expand all", on_click=_set_all_categories, args=(True,),
                       width="stretch")
    collapse_col.button("Collapse all", on_click=_set_all_categories, args=(False,),
                         width="stretch")

    grouped: dict[str, list[tuple[str, list]]] = {c: [] for c in CATEGORY_ORDER}
    for tag, block_entries in blocks.items():
        grouped[category_for(tag)].append((tag, block_entries))

    any_match = False
    for category in CATEGORY_ORDER:
        items = grouped[category]
        if not items:
            continue

        if query:
            items = [
                (tag, es) for tag, es in items
                if query in tag.lower()
                or query in category.lower()
                or any(query in e.domain.lower() for e in es)
            ]
        if not items:
            continue
        any_match = True

        slug = CATEGORY_SLUGS[category]
        open_key = f"cat_open_{slug}"
        is_open = st.session_state.get(open_key, True)
        # A search match always shows its block, even in a collapsed section —
        # the stored preference (is_open) is untouched and resumes once the
        # search is cleared.
        effective_open = is_open or bool(query)

        header_col, toggle_col = st.columns([6, 1], vertical_alignment="center")
        header_col.markdown(
            f'<div style="display:flex; align-items:center; gap:8px; '
            f'margin:1.2em 0 0.4em;">'
            f'<span style="width:10px; height:10px; border-radius:50%; '
            f'background:{color_var(items[0][0])}; flex:none;"></span>'
            f'<span style="font-weight:700; font-size:0.85em; '
            f'letter-spacing:0.04em; text-transform:uppercase; '
            f'color:#71717a;">{category}</span>'
            f'</div>',
            unsafe_allow_html=True,
        )
        toggle_col.button(
            "▾ Collapse" if is_open else "▸ Expand",
            key=f"toggle_{slug}", width="stretch",
            on_click=_toggle_category, args=(slug,),
        )

        if effective_open:
            for tag, block_entries in items:
                _render_block_row(tag, block_entries)
                st.divider()
        else:
            st.caption(f"{len(items)} block(s) hidden.")
            st.divider()

    if query and not any_match:
        st.info(f'No blocks match "{query}".')

    # --- Add domain -----------------------------------------------------------

    add_l, _add_r = st.columns([1, 1])
    with add_l:
        st.subheader("Add New Domain")
        with st.form("add_domain_form"):
            new_domain = st.text_input("Domain (e.g. .github.com)")
            target_block = st.selectbox(
                "Block", options=["ALWAYS ON"] + list(blocks.keys())
            )
            submitted = st.form_submit_button("Add")
            if submitted and new_domain:
                tag = None if target_block == "ALWAYS ON" else target_block
                config_io.add_domain(new_domain, block_tag=tag)
                st.session_state.entries = config_io.read_allowed_domains()
                _drop_dom_keys()
                st.success(f"Added {new_domain}")
                st.rerun()

    st.subheader("Current File Content (Preview)")
    with st.expander("Show raw content"):
        raw_lines = []
        for entry in entries:
            if entry.domain:
                prefix = "# " if entry.is_commented else ""
                raw_lines.append(f"{prefix}{entry.domain}")
            else:
                raw_lines.append(entry.raw_line.strip())
        st.code("\n".join(raw_lines))
