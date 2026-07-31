import os
import sys

import streamlit as st

sys.path.insert(0, os.path.dirname(__file__))

from lib import proxy_allowlist_view, status_view

st.set_page_config(page_title="Sandbox Control Dashboard", layout="wide")

st.title("Sandbox Control Dashboard")
st.caption("Ops console for the hardened sandbox stack.")

tab_status, tab_allowlist = st.tabs(["Status", "Proxy Allowlist"])

with tab_status:
    status_view.render()

with tab_allowlist:
    proxy_allowlist_view.render()
