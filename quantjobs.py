#!/usr/bin/env python3
"""
quantjobs — scrape internship / graduate postings from quant firm job boards.

Author:  Mykhaylo Gershman <mgershman@ethz.ch>
License: MIT (see LICENSE)

Zero dependencies: standard library only.

  ./quantjobs.py scrape --category swe
  ./quantjobs.py scrape --category quant-trading --level intern --out jobs.csv
  ./quantjobs.py companies                 # show the configured firm list
  ./quantjobs.py verify                    # check every board still resolves
  ./quantjobs.py discover https://firm.com/careers    # find a firm's ATS token
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import datetime as dt
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from html import unescape
from typing import Any, Iterable

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# The config normally sits beside this script, which is what makes a checkout
# self-contained. $QUANTJOBS_CONFIG overrides it, and the Mac app reads the same
# variable, so pointing one tool somewhere else points both.
HERE = os.path.expanduser(os.environ.get("QUANTJOBS_CONFIG") or "") or SCRIPT_DIR
COMPANIES_FILE = os.path.join(HERE, "companies.json")
CATEGORIES_FILE = os.path.join(HERE, "categories.json")
LOCATIONS_FILE = os.path.join(HERE, "locations.json")
SEEN_FILE = os.path.join(HERE, ".seen.json")
# Written by the Mac app: saved / applied / hidden postings.
TRACKED_FILE = os.path.join(HERE, ".tracked.json")

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
     "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
TIMEOUT = 25


# ─────────────────────────────── http ────────────────────────────────

class FetchError(Exception):
    pass


def http(url: str, *, data: bytes | None = None, headers: dict | None = None,
         retries: int = 2) -> bytes:
    """GET (or POST if data) with retry on transient failures."""
    hdrs = {"User-Agent": UA, "Accept": "application/json, text/html;q=0.9"}
    if data is not None:
        hdrs["Content-Type"] = "application/json"
    hdrs.update(headers or {})

    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=data, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            # 4xx is a real answer (bad token) — don't burn retries on it.
            if 400 <= e.code < 500:
                raise FetchError(f"HTTP {e.code}") from e
            last = FetchError(f"HTTP {e.code}")
        except Exception as e:  # timeouts, DNS, resets
            last = FetchError(type(e).__name__)
        if attempt < retries:
            time.sleep(1.5 * (attempt + 1))
    raise last or FetchError("unknown")


def http_json(url: str, **kw) -> Any:
    raw = http(url, **kw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise FetchError(f"bad JSON ({e})") from e


def strip_html(s: str | None) -> str:
    if not s:
        return ""
    s = re.sub(r"<[^>]+>", " ", unescape(s))
    return re.sub(r"\s+", " ", s).strip()


def iso_date(v: Any) -> str:
    """Normalise the many date shapes these APIs emit to YYYY-MM-DD."""
    if v in (None, ""):
        return ""
    if isinstance(v, (int, float)):  # epoch millis (Lever)
        try:
            return dt.datetime.fromtimestamp(v / 1000, dt.timezone.utc).strftime("%Y-%m-%d")
        except (ValueError, OSError, OverflowError):
            return ""
    m = re.match(r"(\d{4}-\d{2}-\d{2})", str(v))
    return m.group(1) if m else ""


# ───────────────────────────── adapters ──────────────────────────────
#
# Each adapter takes the company config dict and returns a list of raw
# job dicts: title / location / url / posted / department / description.
# Adding a new ATS means writing one function and registering it below.

def fetch_greenhouse(c: dict, deep: bool) -> list[dict]:
    token = c["token"]
    url = f"https://boards-api.greenhouse.io/v1/boards/{token}/jobs"
    if deep:
        url += "?content=true"
    payload = http_json(url)
    out = []
    for j in payload.get("jobs", []):
        offices = ", ".join(o.get("name", "") for o in j.get("offices", []) if o.get("name"))
        depts = ", ".join(d.get("name", "") for d in j.get("departments", []) if d.get("name"))
        out.append({
            "title": j.get("title", ""),
            "location": (j.get("location") or {}).get("name", "") or offices,
            "url": j.get("absolute_url", ""),
            "posted": iso_date(j.get("updated_at") or j.get("first_published")),
            "department": depts,
            "description": strip_html(j.get("content")) if deep else "",
        })
    return out


def fetch_lever(c: dict, deep: bool) -> list[dict]:
    token = c["token"]
    payload = http_json(f"https://api.lever.co/v0/postings/{token}?mode=json")
    if not isinstance(payload, list):
        raise FetchError("unexpected Lever payload")
    out = []
    for j in payload:
        cats = j.get("categories") or {}
        out.append({
            "title": j.get("text", ""),
            "location": cats.get("location", "") or "",
            "url": j.get("hostedUrl", ""),
            "posted": iso_date(j.get("createdAt")),
            "department": " / ".join(x for x in (cats.get("team"), cats.get("commitment")) if x),
            # Lever ships the description inline, so 'deep' costs nothing here.
            "description": j.get("descriptionPlain", "") or "",
        })
    return out


def fetch_ashby(c: dict, deep: bool) -> list[dict]:
    """Ashby's public posting API.

    The older non-user-graphql endpoint used to work, but Ashby dropped
    `departmentName` / `publishedDate` from that schema and now rejects the
    query outright. This REST board is public, carries the publish date, and
    ships descriptions inline — so 'deep' costs nothing here, same as Lever.
    """
    token = c["token"]
    payload = http_json(f"https://api.ashbyhq.com/posting-api/job-board/{token}")
    jobs = payload.get("jobs")
    if jobs is None:
        raise FetchError("no such Ashby board")
    out = []
    for j in jobs:
        out.append({
            "title": j.get("title", ""),
            "location": j.get("location", "") or "",
            "url": j.get("jobUrl", ""),
            "posted": iso_date(j.get("publishedAt")),
            "department": " / ".join(
                x for x in (j.get("department"), j.get("employmentType")) if x),
            "description": j.get("descriptionPlain", "") or "",
        })
    return out


def fetch_smartrecruiters(c: dict, deep: bool) -> list[dict]:
    token = c["token"]
    out, offset = [], 0
    while True:
        url = (f"https://api.smartrecruiters.com/v1/companies/{token}"
               f"/postings?limit=100&offset={offset}")
        payload = http_json(url)
        batch = payload.get("content", [])
        for j in batch:
            loc = j.get("location") or {}
            where = ", ".join(x for x in (loc.get("city"), loc.get("region"),
                                          loc.get("country")) if x)
            out.append({
                "title": j.get("name", ""),
                "location": where or ("Remote" if loc.get("remote") else ""),
                "url": f"https://jobs.smartrecruiters.com/{token}/{j.get('id','')}",
                "posted": iso_date(j.get("releasedDate")),
                "department": (j.get("department") or {}).get("label", ""),
                "description": "",
            })
        offset += len(batch)
        if not batch or offset >= payload.get("totalFound", 0) or offset > 2000:
            break
    return out


# Every Workday tenant sits behind the same front end, and a big board is a
# hundred-plus round trips because pages cap at 20. A full run once reported seven
# Workday boards broken that all answered fine on their own, so there is a ceiling
# somewhere. Six in flight is the compromise: those same seven boards verify
# cleanly at that rate, and it barely costs anything against eight workers.
_WORKDAY_GATE = threading.Semaphore(6)


def fetch_workday(c: dict, deep: bool) -> list[dict]:
    """Workday CXS. Config needs: host (tenant.wdN.myworkdayjobs.com), tenant, site."""
    host, tenant, site = c.get("host"), c.get("tenant"), c.get("site")
    if not all((host, tenant, site)):
        raise FetchError("workday needs host/tenant/site in companies.json")
    endpoint = f"https://{host}/wday/cxs/{tenant}/{site}/jobs"
    out, offset, total = [], 0, None
    while True:
        # Workday caps a page at 20, so a big board is a lot of round trips;
        # an optional `query` narrows it server-side.
        body = json.dumps({"appliedFacets": {}, "limit": 20, "offset": offset,
                           "searchText": c.get("query", "")}).encode()
        with _WORKDAY_GATE:
            payload = http_json(endpoint, data=body)
        batch = payload.get("jobPostings", [])
        # Workday reports the count on the first page only; every page after
        # that says total=0, which would end the loop after 40 rows.
        if total is None:
            total = payload.get("total") or 0
        for j in batch:
            path = j.get("externalPath", "")
            out.append({
                "title": j.get("title", ""),
                "location": j.get("locationsText", "") or "",
                "url": f"https://{host}/en-US/{site}{path}",
                "posted": "",  # Workday gives "Posted 5 Days Ago", not a date
                "department": "",
                "description": " ".join(j.get("bulletFields") or []),
            })
        offset += len(batch)
        if not batch or (total and offset >= total) or offset > 2000:
            break
    return out


def amazon_date(v: Any) -> str:
    """amazon.jobs prints dates as 'July 31, 2026'."""
    try:
        return dt.datetime.strptime(str(v).strip(), "%B %d, %Y").strftime("%Y-%m-%d")
    except (ValueError, TypeError):
        return ""


def fetch_amazon(c: dict, deep: bool) -> list[dict]:
    """amazon.jobs public search API.

    There's no board slug here — the whole site is one search index — so
    `query` narrows it up front. It defaults to 'intern' because pulling all
    ~15k Amazon postings to filter locally would be silly.
    """
    query = c.get("query", "intern")
    out, offset = [], 0
    while True:
        url = "https://www.amazon.jobs/en/search.json?" + urllib.parse.urlencode({
            "base_query": query, "result_limit": 100, "offset": offset,
            "sort": "recent",
        })
        payload = http_json(url)
        batch = payload.get("jobs", [])
        for j in batch:
            body = " ".join(x for x in (j.get("description_short"),
                                        j.get("basic_qualifications")) if x)
            out.append({
                "title": j.get("title", ""),
                "location": j.get("normalized_location", "") or "",
                "url": "https://www.amazon.jobs" + (j.get("job_path") or ""),
                "posted": amazon_date(j.get("posted_date")),
                "department": j.get("job_category", "") or "",
                "description": strip_html(body) if deep else "",
            })
        offset += len(batch)
        # The API stops serving results past ~1000.
        if not batch or offset >= payload.get("hits", 0) or offset >= 1000:
            break
    return out


def epoch_date(v: Any) -> str:
    """Eightfold hands back seconds, not the milliseconds Lever uses."""
    try:
        return dt.datetime.fromtimestamp(float(v), dt.timezone.utc).strftime("%Y-%m-%d")
    except (TypeError, ValueError, OSError, OverflowError):
        return ""


def fetch_eightfold(c: dict, deep: bool) -> list[dict]:
    """Eightfold career sites (Netflix and friends).

    Config: host (explore.jobs.netflix.net) + tenant (the `domain` parameter).
    """
    host, domain = c.get("host"), c.get("tenant")
    if not host or not domain:
        raise FetchError("eightfold needs host + tenant (its domain)")
    out, start = [], 0
    while True:
        url = (f"https://{host}/api/apply/v2/jobs?" + urllib.parse.urlencode({
            "domain": domain, "start": start, "num": 100,
            "query": c.get("query", ""), "sort_by": "timestamp"}))
        payload = http_json(url)
        batch = payload.get("positions", [])
        for j in batch:
            places = j.get("locations") or ([j["location"]] if j.get("location") else [])
            out.append({
                "title": j.get("name", ""),
                "location": "; ".join(places),
                "url": j.get("canonicalPositionUrl", ""),
                "posted": epoch_date(j.get("t_create") or j.get("t_update")),
                "department": " / ".join(
                    x for x in (j.get("department"), j.get("business_unit")) if x),
                "description": strip_html(j.get("job_description")) if deep else "",
            })
        start += len(batch)
        if not batch or start >= payload.get("count", 0) or start > 2000:
            break
    return out


def fetch_jibe(c: dict, deep: bool) -> list[dict]:
    """Jibe-style careers sites — SIG's is one. Config: host."""
    host = c.get("host")
    if not host:
        raise FetchError("jibe needs a host")
    out, page = [], 1
    while True:
        url = f"https://{host}/api/jobs?page={page}&limit=100"
        payload = http_json(url)
        batch = payload.get("jobs", [])
        for wrapper in batch:
            j = wrapper.get("data") or {}
            cats = j.get("category")
            out.append({
                "title": j.get("title", ""),
                "location": j.get("full_location") or ", ".join(
                    x for x in (j.get("city"), j.get("country")) if x),
                "url": j.get("apply_url", ""),
                "posted": iso_date(j.get("create_date")),
                "department": ", ".join(cats) if isinstance(cats, list)
                              else (j.get("department") or ""),
                "description": strip_html(j.get("description")) if deep else "",
            })
        page += 1
        if not batch or len(out) >= payload.get("totalCount", 0) or len(out) > 2000:
            break
    return out


def fetch_uber(c: dict, deep: bool) -> list[dict]:
    """Uber's own careers API."""
    out, page = [], 0
    while True:
        body = json.dumps({"params": {"page": page, "limit": 100},
                           "page": page, "limit": 100}).encode()
        payload = http_json(
            "https://www.uber.com/api/loadSearchJobsResults?localeCode=en",
            data=body,
            headers={"Referer": "https://www.uber.com/us/en/careers/list/",
                     "x-csrf-token": "x"})
        results = ((payload.get("data") or {}).get("results")) or []
        for j in results:
            spots = [s for s in (j.get("allLocations")
                                 or [j.get("location")] or []) if s]
            where = "; ".join(
                ", ".join(x for x in (s.get("city"), s.get("region"),
                                      s.get("countryName")) if x)
                for s in spots)
            out.append({
                "title": j.get("title", ""),
                "location": where,
                "url": f"https://www.uber.com/global/en/careers/list/{j.get('id','')}/",
                "posted": iso_date(j.get("creationDate")),
                "department": j.get("department") or j.get("team") or "",
                "description": strip_html(j.get("description")) if deep else "",
            })
        page += 1
        if not results or len(out) > 2000:
            break
    return out


def fetch_wolverine(c: dict, deep: bool) -> list[dict]:
    """Wolverine Trading's in-house listing. One flat array, no paging."""
    payload = http_json("https://www.wolve.com/api/positions")
    if not isinstance(payload, list):
        raise FetchError("unexpected Wolverine payload")
    out = []
    for j in payload:
        if str(j.get("Status", "")).lower() in ("closed", "filled"):
            continue
        where = ", ".join(str(x) for x in (j.get("City"), j.get("State")) if x) \
            or (j.get("Location") or "")
        out.append({
            "title": j.get("Title", ""),
            "location": where,
            "url": f"https://www.wolve.com/careers?job={j.get('ID', '')}",
            "posted": iso_date(j.get("DateOpened") or j.get("CreatedOn")),
            "department": j.get("JobDepartment") or j.get("Category") or "",
            "description": strip_html(j.get("Description")) if deep else "",
        })
    return out


# Their careers site is server-rendered WordPress with the REST API switched
# off, so this is the one adapter that reads HTML instead of JSON.
CITADEL_CARD = re.compile(
    r'<a\s[^>]*class="[^"]*careers-listing-card[^"]*"[^>]*?href="([^"]+)"'
    r'[^>]*?data-position="([^"]*)"(.*?)</a>', re.S)
CITADEL_LOC = re.compile(r'careers-listing-card__location"\s*>\s*([^<]*)')
CITADEL_TOTAL = re.compile(r'class="total-post"[^>]*>(\d+)<')

# Both Citadel boards sit behind one Cloudflare tenant, so with eight workers
# running they throttle each other into 403s. One request at a time, paced.
_CITADEL_GATE = threading.Lock()
_CITADEL_LAST = [0.0]


def citadel_get(url: str) -> str:
    with _CITADEL_GATE:
        gap = time.monotonic() - _CITADEL_LAST[0]
        if gap < 1.2:
            time.sleep(1.2 - gap)
        try:
            raw = http(url, headers=BROWSER_HEADERS)
        except FetchError as e:
            if "403" not in str(e):
                raise
            for wait in (6, 15):
                time.sleep(wait)
                try:
                    raw = http(url, headers=BROWSER_HEADERS)
                    break
                except FetchError:
                    continue
            else:
                raise
        _CITADEL_LAST[0] = time.monotonic()
        return raw.decode("utf-8", "replace")


# Cloudflare in front of it wants a browser-shaped request.
BROWSER_HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Upgrade-Insecure-Requests": "1",
}


# HRT publishes nothing a job board would recognise: its Greenhouse token is a
# talent-community placeholder with three generic entries, and the careers page
# links only to that. The real roles are a WordPress custom post type — not in
# the REST API, but every one of them is in the sitemap, and each page carries
# its title and offices in markup.
HRT_TITLE = re.compile(r"<title>(.*?)</title>", re.S)
HRT_SUMMARY = re.compile(r"class='summary-info'>(.*?)</div>", re.S)


def leading_city(title: str) -> str:
    """The office out of "London Technology Internship".

    Checked against the gazetteer rather than accepted on faith:
    parse_locations() treats any unrecognised words as a city, so feeding it a
    job title happily returns "London Technology Internship" as a place.
    Longest match first, so "New York" beats "New".
    """
    g = gazetteer()
    words = re.findall(r"[A-Za-z]+", title)
    for n in range(min(3, len(words)), 0, -1):
        candidate = " ".join(words[:n])
        if candidate.lower() in g.get("cities", {}):
            return g["cities"][candidate.lower()]["name"]
    return ""


def sitemap_one(url: str, title_loc: bool = False, firm: str = "") -> dict | None:
    """Title and offices from a single job page."""
    try:
        html = http(url, headers=BROWSER_HEADERS).decode("utf-8", "replace")
    except FetchError:
        return None
    m = HRT_TITLE.search(html)
    if not m:
        return None
    title = strip_html(m.group(1))
    # Page titles carry the firm: "London Technology Internship - Marshall Wace",
    # "AI Researcher | Hudson River Trading". Drop whichever separator is used.
    for sep in ("|", " - ", " – ", " — "):
        head = title.split(sep)[0].strip()
        if firm and title != head and firm.lower() in title.lower():
            title = head
            break
        if sep == "|" and title != head:
            title = head
            break
    title = title.strip()
    if not title:
        return None
    where = ""
    if summary := HRT_SUMMARY.search(html):
        # "London <span>|</span> New York" — the separators are markup.
        parts = [strip_html(x) for x in re.split(r"<[^>]+>", summary.group(1))]
        where = ", ".join(p for p in (x.strip() for x in parts) if p and p != "|")
    if not where and title_loc:
        where = leading_city(title)
    return {"title": title, "location": where, "url": url,
            "posted": "", "department": "", "description": ""}


def fetch_sitemap(c: dict, deep: bool) -> list[dict]:
    """Firms whose real roles exist only as pages in their own sitemap.

    Some sites publish nothing a job board would recognise — no ATS, no feed,
    and a careers page that is prose — yet every role has a URL, because the CMS
    lists them for search engines. Config:

        host      the domain
        sitemap   which sitemap file, e.g. "hrt_jobs-sitemap.xml"
        path      substring a URL must contain to count as a job
        title_loc true to read the office out of the title, for sites that
                  write "London Technology Internship" and state it nowhere else
    """
    host = c.get("host", "")
    sitemap = c.get("sitemap", "")
    if not host or not sitemap:
        raise FetchError("sitemap adapter needs host and sitemap in companies.json")
    marker = c.get("path", "/")
    xml = http(f"https://{host}/{sitemap}",
               headers=BROWSER_HEADERS).decode("utf-8", "replace")
    urls = [u for u in re.findall(r"<loc>([^<]+)</loc>", xml) if marker in u]
    if not urls:
        raise FetchError(f"no job pages in {sitemap}")

    # The sitemap's <lastmod> is deliberately ignored: every entry carries the
    # same timestamp, so it records when the sitemap was regenerated rather than
    # when anything was posted. Using it would date all 72 roles today and float
    # them above genuinely fresh postings. Undated is honest; wrong is not.
    title_loc = bool(c.get("title_loc"))
    firm = c.get("name", "")
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        out = [job for job in ex.map(lambda u: sitemap_one(u, title_loc, firm), urls)
               if job]

    # One page per role means a network hiccup silently shrinks the board, and a
    # board that quietly returns 60 of 72 roles is worse than one that says it
    # failed. Tolerate the odd miss, report anything worse.
    missing = len(urls) - len(out)
    if missing > max(3, len(urls) // 10):
        raise FetchError(f"only read {len(out)} of {len(urls)} job pages")
    return out


# Jane Street's Greenhouse board carries experienced hires only — 177 roles and
# not one internship. Students and new grads live in a JSON file its own careers
# page fetches, which is where the ~44 internships and ~23 new-grad roles are.
JANESTREET_CITIES = {"NYC": "New York, NY", "LDN": "London", "HKG": "Hong Kong",
                     "SGP": "Singapore", "AMS": "Amsterdam"}

# A handful of letters are swapped for Lisu lookalikes, presumably to make the
# titles awkward to scrape: "\ua4dfachine \ua4e1earning \ua4e3esearcher".
JANESTREET_HOMOGLYPHS = {"\ua4df": "M", "\ua4e1": "L", "\ua4e3": "R"}


def janestreet_text(s: str) -> str:
    for bad, good in JANESTREET_HOMOGLYPHS.items():
        s = s.replace(bad, good)
    return s


def fetch_janestreet(c: dict, deep: bool) -> list[dict]:
    """Jane Street's own careers JSON."""
    host = c.get("host", "www.janestreet.com")
    payload = http_json(f"https://{host}/jobs/main.json", headers=BROWSER_HEADERS)
    if not isinstance(payload, list):
        raise FetchError("unexpected Jane Street payload")
    out = []
    for j in payload:
        title = janestreet_text(strip_html(j.get("position", "")))
        if not title:
            continue
        ident = j.get("id")
        # Availability is the level: "Summer Internship", "Full-Time: New Grad",
        # "Full-Time: Experienced". Kept in the department so the level matcher
        # sees it — the titles themselves say nothing about seniority.
        availability = j.get("availability", "") or ""
        team = " / ".join(x for x in (j.get("category"), j.get("team")) if x)
        out.append({
            "title": title,
            "location": JANESTREET_CITIES.get(j.get("city", ""), j.get("city", "")),
            "url": f"https://{host}/join-jane-street/position/{ident}/" if ident else "",
            "posted": "",          # not published
            "department": " / ".join(x for x in (availability, team) if x),
            "description": strip_html(j.get("overview")) if deep else "",
        })
    if not out:
        raise FetchError("no roles in the Jane Street feed")
    return out


def fetch_citadel(c: dict, deep: bool) -> list[dict]:
    """Citadel / Citadel Securities. Config: host."""
    host = c.get("host")
    if not host:
        raise FetchError("citadel needs a host")

    out, page, total = [], 1, None
    while page <= 30:
        url = (f"https://{host}/careers/open-opportunities/"
               if page == 1 else
               f"https://{host}/careers/open-opportunities/page/{page}/")
        html = citadel_get(url)
        if total is None:
            m = CITADEL_TOTAL.search(html)
            total = int(m.group(1)) if m else 0

        cards = CITADEL_CARD.findall(html)
        if not cards:
            break
        for href, title, rest in cards:
            loc = CITADEL_LOC.search(rest)
            out.append({
                "title": strip_html(title),
                "location": strip_html(loc.group(1)) if loc else "",
                "url": href,
                # The listing carries no date; only the detail pages do, and
                # that would be one request per posting.
                "posted": "",
                "department": "",
                "description": "",
            })
        if total and len(out) >= total:
            break
        page += 1
    return out


OPTIVER_JOB = re.compile(
    r'<a\s+href="(/join-us/jobs/([a-z0-9-]+)/([a-z0-9-]+)/[^"#]+)"[^>]*>([^<]+)</a>\s*</h3>'
    r'\s*<p[^>]*>([^<]*)</p>', re.I)


def fetch_optiver(c: dict, deep: bool) -> list[dict]:
    """Optiver's own jobs pages.

    Deliberately partial: the listing renders 16 roles and then loads the rest
    with JavaScript, and there's no API, sitemap or page parameter behind it
    (every ?page/?offset/?limit variant returns the same 16). So this walks the
    per-category pages, which gets the newest 16 of each rather than all of them.
    """
    base = "https://www.optiver.com"
    root = http(base + "/join-us/jobs/", headers=BROWSER_HEADERS).decode("utf-8", "replace")

    # Take the category list from the page rather than hard-coding it.
    cats = []
    for m in re.finditer(r'href="/join-us/jobs/([a-z0-9-]+)/[a-z0-9-]+/', root):
        if m.group(1) not in cats:
            cats.append(m.group(1))

    out, seen = [], set()
    for html in [root] + [
        http(f"{base}/join-us/jobs/{cat}/",
             headers=BROWSER_HEADERS).decode("utf-8", "replace")
        for cat in cats[:8]
    ]:
        for path, cat, city, title, loc in OPTIVER_JOB.findall(html):
            if path in seen:
                continue
            seen.add(path)
            out.append({
                "title": strip_html(title),
                "location": strip_html(loc) or city.replace("-", " ").title(),
                "url": base + path,
                "posted": "",          # not shown in the listing
                "department": cat.replace("-", " ").title(),
                "description": "",
            })
    return out


# Anchor first, then the location span in a short window after it. One regex
# spanning both used `.*?` across the whole document, which let a single match
# swallow the anchors in between — 58 roles on the page came back as 10.
TWOSIGMA_ANCHOR = re.compile(
    r'href="(https://careers\.twosigma\.com/careers/JobDetail/[^"#]+)"[^>]*>([^<]*)</a>')
TWOSIGMA_LOC = re.compile(r'paragraph_inner-span">\s*([^<]*)')


def twosigma_location(raw: str) -> str:
    """"United States - NY New York" is country-first; flip it round."""
    parts = [p.strip() for p in raw.split(" - ") if p.strip()]
    if len(parts) != 2:
        return raw.strip()
    country, rest = parts
    m = re.match(r"^([A-Z]{2})\s+(.+)$", rest)
    if m:
        return f"{m.group(2)}, {m.group(1)}, {country}"
    return f"{rest}, {country}"


def fetch_twosigma(c: dict, deep: bool) -> list[dict]:
    """Two Sigma's Avature portal.

    The listing only renders once `jobOffset` is present — a bare /OpenRoles
    returns the shell. Ten per page, and the links are absolute.
    """
    out, seen, offset = [], set(), 0
    while offset <= 400:
        html = http(f"https://careers.twosigma.com/careers/OpenRoles?jobOffset={offset}",
                    headers=BROWSER_HEADERS).decode("utf-8", "replace")
        added = 0
        for m in TWOSIGMA_ANCHOR.finditer(html):
            url = m.group(1)
            if url in seen:
                continue
            seen.add(url)
            added += 1
            window = html[m.end():m.end() + 900]
            found = TWOSIGMA_LOC.search(window)
            out.append({
                "title": strip_html(m.group(2)),
                "location": twosigma_location(strip_html(found.group(1))) if found else "",
                "url": url,
                "posted": "",          # not shown in the listing
                "department": "",
                "description": "",
            })
        if added == 0:
            break
        offset += 10
    return out


SIMPLIFY_URL = ("https://raw.githubusercontent.com/SimplifyJobs/"
                "Summer2027-Internships/dev/.github/scripts/listings.json")
_SIMPLIFY_CACHE: dict[str, list] = {}

# A second-hand listing is only worth showing if the posting is still there,
# so anything from an aggregator gets its link checked before we believe it.
LINK_OK, LINK_DEAD, LINK_BLOCKED = "ok", "dead", "blocked"


def check_link(url: str, timeout: int = 12) -> str:
    """Classify a job link: reachable, gone, or can't tell.

    A 404/410 means the posting has been taken down. A 403/400 usually means
    the firm blocks scripted requests (Meta does), which says nothing about
    whether the job exists — so that stays 'blocked' rather than 'dead', and
    the row survives with a caveat instead of being silently dropped.
    """
    if not url:
        return LINK_DEAD
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return LINK_OK if r.status < 400 else LINK_BLOCKED
    except urllib.error.HTTPError as e:
        if e.code in (404, 410):
            return LINK_DEAD
        return LINK_BLOCKED
    except Exception:
        return LINK_BLOCKED          # timeout, DNS, reset — inconclusive


def verify_links(jobs: list[dict], workers: int = 6) -> list[dict]:
    """Check every link in parallel, drop the ones that are definitely gone."""
    if not jobs:
        return jobs
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for job, status in zip(jobs, ex.map(lambda j: check_link(j["url"]), jobs)):
            job["link_status"] = status
    return [j for j in jobs if j["link_status"] != LINK_DEAD]


def fetch_simplify(c: dict, deep: bool) -> list[dict]:
    """Community internship feed, for firms with no reachable board of their own.

    Apple, Google, Meta and Microsoft publish nothing a script can read, but
    Simplify and the Pitt CS Club maintain a public listings.json that covers
    them, with links straight to each firm's own application page.

    Second-hand by nature: it's internships only, and its freshness depends on
    that project rather than on the firm. `query` is the exact company name;
    `host` overrides the feed URL when the season's repo rolls over.
    """
    url = c.get("host") or SIMPLIFY_URL
    if url not in _SIMPLIFY_CACHE:
        # One download serves every firm using this source in a run.
        _SIMPLIFY_CACHE[url] = http_json(url)
    listings = _SIMPLIFY_CACHE[url]
    if not isinstance(listings, list):
        raise FetchError("unexpected Simplify payload")

    wanted = (c.get("query") or c["name"]).strip().lower()
    # Aggregated rows go stale quietly, so drop anything long in the tooth.
    max_age = int(c.get("max_age_days", 120))
    cutoff = (dt.date.today() - dt.timedelta(days=max_age)).isoformat()

    out = []
    for j in listings:
        if not j.get("active", True) or not j.get("is_visible", True):
            continue
        if (j.get("company_name") or "").strip().lower() != wanted:
            continue
        posted = epoch_date(j.get("date_posted"))
        if posted and posted < cutoff:
            continue
        out.append({
            "title": j.get("title", ""),
            "location": "; ".join(j.get("locations") or []),
            "url": j.get("url", ""),
            "posted": posted,
            "department": j.get("category", "") or "",
            "description": "",
        })
    if not out:
        raise FetchError(f"no current '{wanted}' listings in the Simplify feed")

    # This is the whole point of a second-hand source: confirm the posting is
    # still up before showing it.
    return verify_links(out)


ADAPTERS = {
    "greenhouse": fetch_greenhouse,
    "lever": fetch_lever,
    "ashby": fetch_ashby,
    "smartrecruiters": fetch_smartrecruiters,
    "workday": fetch_workday,
    "amazon": fetch_amazon,
    "eightfold": fetch_eightfold,
    "jibe": fetch_jibe,
    "uber": fetch_uber,
    "wolverine": fetch_wolverine,
    "citadel": fetch_citadel,
    "janestreet": fetch_janestreet,
    "sitemap": fetch_sitemap,
    "optiver": fetch_optiver,
    "twosigma": fetch_twosigma,
    "simplify": fetch_simplify,
}


# ─────────────────────────── locations ───────────────────────────────
#
# Boards describe the same place a dozen ways: "US, CA, Santa Clara",
# "Santa Clara, California, United States", "Austin, TX; New York",
# "New York, London, or Paris". This turns any of them into a list of
# {city, region, country, continent} so they can be grouped and filtered.

_GAZETTEER = None

# Splits one string into separate places. Commas are *not* here — inside a
# group they separate city from region from country.
_PLACE_SPLIT = re.compile(
    r"\s*[;|]\s*|\s*/\s*|\s+[-–]\s+|\s+\bor\b\s+|\s+\band\b\s+", re.I)
_PARENS = re.compile(r"\([^)]*\)")
# Greenhouse writes "3 Locations" when a posting spans several offices.
_COUNT_ONLY = re.compile(r"^\d+\s+locations?$", re.I)


def gazetteer() -> dict:
    global _GAZETTEER
    if _GAZETTEER is None:
        _GAZETTEER = load_json(LOCATIONS_FILE, default={
            "countries": {}, "countryAliases": {}, "regions": {},
            "cities": {}, "remoteTerms": [], "noiseTerms": [],
        })
    return _GAZETTEER


def _place(city: str, region: str, region_abbr: str, country: str, g: dict) -> dict:
    info = g["countries"].get(country or "", {})
    return {
        "city": city,
        "region": region,
        "region_abbr": region_abbr,
        "country": country,
        "country_name": info.get("name", ""),
        "continent": info.get("continent", "") or "Other",
    }


def _parse_group(group: str, g: dict) -> list[dict]:
    """Classify the comma-separated parts of one place.

    Order matters more than it looks. Cities are tested first because plenty of
    US state names are also city names ("New York", "Washington"). Regions are
    tested before countries because two-letter state codes collide with country
    codes — IL is both Illinois and Israel, CA both California and Canada — and
    a bare `key in countryAliases` check sent every Chicago job to Asia.
    """
    parts = [p.strip() for p in group.split(",") if p.strip()]
    country, region, region_abbr = None, "", ""
    weak_region = None          # a region whose country we couldn't corroborate
    remote = False
    cities, unknown = [], []

    for part in parts:
        key = part.lower().strip(". ")
        if not key or key in g["noiseTerms"] or _COUNT_ONLY.match(key):
            continue
        if key in g["remoteTerms"]:
            remote = True
            continue

        if key in g["cities"]:
            cities.append(g["cities"][key])
            continue

        r = g["regions"].get(key)
        if r is not None:
            # Only read it as a region when something else agrees it's that
            # country — otherwise "Bengaluru, IN" becomes Indiana.
            agrees = (country == r["country"]
                      or (country is None
                          and (not cities
                               or any(c["country"] == r["country"] for c in cities))))
            if agrees:
                region, region_abbr = r["name"], r.get("abbr", "")
                country = country or r["country"]
                continue
            if key not in g["countryAliases"]:
                weak_region = r
                continue

        if country is None and key in g["countryAliases"]:
            country = g["countryAliases"][key]
            continue

        unknown.append(part)

    # "Dublin, OH": nothing corroborated Ohio, but no country was named either,
    # so the state is still the best evidence we have.
    if country is None and weak_region is not None:
        country = weak_region["country"]
        region, region_abbr = weak_region["name"], weak_region.get("abbr", "")

    # An explicit country overrides a city's own only when it doesn't contradict
    # it, so "Amsterdam, Netherlands, London, United Kingdom" keeps both.
    forced = country if (country and (len(cities) <= 1
                         or all(c["country"] == country for c in cities))) else None

    out = []
    for c in cities:
        code = forced or c["country"]
        keep_region = region if code == country else ""
        keep_abbr = region_abbr if code == country else ""
        out.append(_place(c["name"], keep_region, keep_abbr, code, g))

    if not out:
        # "United States - Remote" is a US role, not a placeless one; only fall
        # back to the bare Remote bucket when nothing named a country.
        if remote and not unknown:
            if country:
                out.append(_place("Remote", region, region_abbr, country, g))
            else:
                out.append({"city": "Remote", "region": "", "region_abbr": "",
                            "country": "", "country_name": "",
                            "continent": "Remote"})
            return out
        # No known city — fall back to the free text, then the region, then the
        # country, so something recognisable still reaches the UI.
        name = unknown[0] if unknown else (region or
               g["countries"].get(country or "", {}).get("name", ""))
        if name or country:
            out.append(_place(name, region, region_abbr, country or "", g))
    return out


def parse_locations(raw: str | None) -> list[dict]:
    g = gazetteer()
    if not raw:
        return []
    s = _PARENS.sub(" ", raw)
    s = re.sub(r"\s+", " ", s).strip(" ,-")
    if not s:
        return []

    low = s.lower()
    if any(low == t or low.startswith(t + " ") or low.startswith(t + ",")
           for t in g["remoteTerms"]):
        return [{"city": "Remote", "region": "", "region_abbr": "", "country": "",
                 "country_name": "", "continent": "Remote"}]


    out, seen = [], set()
    for group in _PLACE_SPLIT.split(s):
        for place in _parse_group(group, g):
            key = (place["city"].lower(), place["country"])
            if key not in seen:
                seen.add(key)
                out.append(place)

    # Once something real has been identified, drop the leftovers a split
    # produces — office codes like "UK2", and the "Remote" half of
    # "United States - Remote", which the country already covers.
    if any(p["country"] for p in out):
        out = [p for p in out if p["country"]]
    return out


def format_location(places: list[dict], raw: str = "") -> str:
    """Compact display: 'Santa Clara, CA' / 'London, GB' / 'Tokyo, JP +2'."""
    if not places:
        return raw
    first = places[0]
    tail = first.get("region_abbr") or first.get("country") or ""
    label = f"{first['city']}, {tail}" if first["city"] and tail else \
        (first["city"] or tail)
    if len(places) > 1:
        label += f" +{len(places) - 1}"
    return label


# ──────────────────────────── matching ───────────────────────────────

def phrase_re(phrases: Iterable[str]) -> re.Pattern | None:
    """Build one alternation regex. Word-bounded when the phrase ends
    alphanumerically, so 'intern' won't fire on 'internal' but 'c++' still works.

    A phrase ending in a letter also matches its plural. Without that, the word
    boundary made "graduate" miss "Fresh Graduates", "early career" miss
    "Software Engineer, Early Careers" and "internship" miss a page titled
    "Internships" — real early-career postings dropped on a trailing s.
    """
    parts = []
    for p in phrases:
        p = p.strip().lower()
        if not p:
            continue
        body = re.escape(p).replace(r"\ ", r"[\s\-/]+")
        pre = r"(?<![a-z0-9])" if p[0].isalnum() else ""
        post = r"s?(?![a-z0-9])" if p[-1].isalpha() else (
            r"(?![a-z0-9])" if p[-1].isalnum() else "")
        parts.append(pre + body + post)
    return re.compile("|".join(parts), re.I) if parts else None


# Plurals come free — see phrase_re. Every phrase below has been checked against
# a full 40k-posting run, so the false positives it buys are countable: "Product
# Manager, Workday Student Financial Aid" is the only one, and no category the
# tool ships would show it.
LEVELS = {
    "intern": [
        "intern", "internship", "summer analyst", "summer associate",
        "co-op", "coop", "industrial placement", "work placement",
        "placement student", "summer programme", "summer program", "sophomore",
        "freshman", "penultimate", "student programme", "student program",
        # Bare "student": how Israeli and German boards say intern — KLA's
        # "Motion Control Student", NXP's "Working Student (f/m/d)".
        "student", "praktikant", "praktikum", "undergraduate",
        "insight programme", "insight program", "vacation scheme", "spring week",
    ],
    "newgrad": [
        "new grad", "new graduate", "graduate", "campus", "university",
        "entry level", "junior", "early career", "class of", "trainee",
        "graduate programme", "graduate program", "rotational",
        # Semiconductor firms hire a whole class this way: "New College Grad",
        # "NCG", "Fresh Grads Welcome". Bare "grad" covers all of them.
        "grad", "ncg", "upcoming graduate",
        # Banks call a new-grad seat a full-time analyst, and a plural PhD in a
        # title is campus hiring — singular "PhD" is often a senior role, so
        # only the plural is listed.
        "full time analyst", "fulltime analyst", "phds",
    ],
}
LEVEL_RE = {k: phrase_re(v) for k, v in LEVELS.items()}
# Some boards label a role "Graduate Trader" but mean experienced; these
# tokens veto a level match outright.
SENIOR_RE = phrase_re([
    "senior", "staff", "principal", "lead", "head of", "director", "vp",
    "vice president", "manager", "experienced", "10+ years", "5+ years",
])


def load_json(path: str, default: Any = None) -> Any:
    if not os.path.exists(path):
        if default is not None:
            return default
        sys.exit(f"missing config file: {path}")
    with open(path) as f:
        return json.load(f)


def build_category_matchers(cats: dict) -> dict:
    """Compile each category, and hand a sub-category its parent's rules too.

    A category with a `parent` is a slice of it, not a peer: `cpp` means "the
    SWE roles that are C++", so both sets of rules have to pass. Without the
    parent gate it also matched FPGA and hardware postings, which are C++ jobs
    but not software-engineering ones.
    """
    out = {}
    for name, spec in cats.items():
        out[name] = {
            "include": phrase_re(spec.get("include", [])),
            "exclude": phrase_re(spec.get("exclude", [])),
            "description": spec.get("description", ""),
            "parent": spec.get("parent"),
        }
    for name, spec in cats.items():
        parent = spec.get("parent")
        if parent and parent in out:
            out[name]["parent_include"] = out[parent]["include"]
            out[name]["parent_exclude"] = out[parent]["exclude"]
    return out


def stack_names(cats: dict) -> list[str]:
    """Categories that name a `parent` — they describe a stack, not a discipline."""
    return [k for k, v in cats.items() if v.get("parent")]


def job_stacks(job: dict, cats: dict, matchers: dict, deep: bool) -> set[str]:
    """Which stacks this posting names. Empty means it names none.

    Matched *ungated* — the question is "does this role mention C++", which is
    worth answering whatever category you're looking at. The parent only says
    which discipline the stack belongs to.
    """
    out = set()
    for name in stack_names(cats):
        bare = dict(matchers[name])
        bare.pop("parent_include", None)
        bare.pop("parent_exclude", None)
        if classify(job, bare, "any", deep):
            out.add(name)
    return out


def passes_stacks(job: dict, unwanted: set[str], cats: dict,
                  matchers: dict, deep: bool) -> bool:
    """Exclusion: a posting goes only if it names a stack you ruled out.

    Naming nothing can never rule a posting out, which is what makes this usable
    — 270 of 310 early-career SWE roles name no stack, so a keep-list would have
    to name every stack you'd accept and would empty the list if you missed one.
    """
    if not unwanted:
        return True
    return not (job_stacks(job, cats, matchers, deep) & unwanted)


def classify(job: dict, matcher: dict, level: str, deep: bool) -> bool:
    """Does this posting match the requested category and level?"""
    title = (job.get("title") or "").lower()
    label = f"{title} {(job.get('department') or '').lower()}"
    body = (job.get("description") or "").lower() if deep else ""

    def included(inc) -> bool:
        """Include test: the title/department, or a topic running through the body.

        No signal in the title/department falls back to the description, but only
        if the topic runs through the whole posting. Most firms open every JD with
        the same blurb ("...low-latency programming, FPGA technology, hardware
        acceleration and machine learning..."), which trivially satisfies any
        "mentions it twice" test — so the mentions also have to be spread out
        rather than clustered in one sentence.
        """
        if not inc or inc.search(label):
            return True
        if not body:
            return False
        pos = [m.start() for m in inc.finditer(body)]
        return len(pos) >= 3 and (pos[-1] - pos[0]) >= 400

    if not included(matcher["include"]):
        return False
    # A sub-category has to satisfy its parent as well — see
    # build_category_matchers.
    if not included(matcher.get("parent_include")):
        return False
    # Exclusions are judged on the title only: a C++ role whose description
    # happens to mention "sales" shouldn't be thrown away.
    for exc in (matcher["exclude"], matcher.get("parent_exclude")):
        if exc and exc.search(title):
            return False

    if level != "any":
        # Judge seniority on the title/department only. Almost every JD body
        # says "our internship programme" somewhere, so matching the
        # description would make every posting look like an internship.
        wanted = [level] if level != "intern-or-newgrad" else ["intern", "newgrad"]
        if not any(LEVEL_RE[w].search(label) for w in wanted):
            return False
        if SENIOR_RE and SENIOR_RE.search(title):
            return False
    return True


_TIDY = [re.compile(p, re.I) for p in (
    # Leading: "2026 - ", "2027 Internship – ", "Summer 2027: "
    r"^\s*(19|20)\d{2}\s*[-–—:,]\s*",
    r"^\s*(summer|fall|autumn|winter|spring)\s+(19|20)\d{2}\s*[-–—:,]\s*",
    r"^\s*(19|20)\d{2}\s+(summer\s+)?(internships?|intern|graduate\s+programme|"
    r"graduate\s+program)\s*[-–—:,]\s*",
    r"^\s*(summer\s+)?intern(ship)?s?\s+(19|20)\d{2}\s*[-–—:,]\s*",
    r"^\s*(internships?|intern)\s*[-–—:,]\s*",
    # Trailing: " - Summer 2027", ", 2026", " (Summer 2027)"
    r"\s*[-–—:,]\s*(summer|fall|autumn|winter|spring)?\s*(19|20)\d{2}\s*$",
    r"\s*\(\s*(summer|fall|autumn|winter|spring)?\s*(19|20)\d{2}\s*\)\s*$",
)]


def short_title(title: str) -> str:
    """Strip the seasonal boilerplate boards front-load titles with.

    "2026 - Internship, Quantitative Researcher" is four words of noise before
    the part that tells one row from another. Two passes, because the year has
    to go before the "Internship," rule can see the start of the string.
    """
    out = title or ""
    for _ in range(2):
        for rx in _TIDY:
            out = rx.sub("", out)
    out = out.strip(" -–—:,\t")
    return out if len(out) >= 4 else (title or "")


def detect_level(job: dict) -> str:
    blob = f"{job.get('title','')} {job.get('department','')}".lower()
    hits = [k for k, rx in LEVEL_RE.items() if rx.search(blob)]
    if "intern" in hits:
        return "intern"
    return hits[0] if hits else ""


# ───────────────────────────── scraping ──────────────────────────────

def board_label(c: dict) -> str:
    """How to name a board in progress and error output.

    A firm can appear more than once, because plenty of them keep graduate
    hiring on a separate portal their main board never lists — Millennium's
    campus site is one. Postings still carry the plain firm name; only the
    config lines and the messages about them need telling apart.
    """
    return f"{c['name']} · {c['board']}" if c.get("board") else c["name"]


def scrape_one(c: dict, deep: bool) -> tuple[dict, list[dict], str | None]:
    adapter = ADAPTERS.get(c.get("ats", ""))
    if not adapter:
        return c, [], f"unknown ats '{c.get('ats')}'"
    try:
        jobs = adapter(c, deep)
    except FetchError as e:
        return c, [], str(e)
    except Exception as e:  # adapter bug / shape change — never kill the run
        return c, [], f"{type(e).__name__}: {e}"
    for j in jobs:
        j["company"] = c["name"]
        j["ats"] = c["ats"]
        j["tags"] = ",".join(c.get("tags", []))
    return c, jobs, None


# Roughly how long each kind of board takes. The slow ones are slow because
# they page HTML ten rows at a time or sit behind a rate limit, and if they
# start last everything else waits on them — so they go first.
ATS_COST = {
    "citadel": 100, "twosigma": 90, "eightfold": 80, "sitemap": 70, "jibe": 40,
    "workday": 30, "optiver": 20, "amazon": 20, "simplify": 15,
    "uber": 10, "smartrecruiters": 8, "wolverine": 3,
}


def by_expected_cost(companies: list[dict]) -> list[dict]:
    """Slowest boards first, so they overlap the quick ones."""
    return sorted(companies, key=lambda c: -ATS_COST.get(c.get("ats", ""), 1))


def scrape(companies: list[dict], deep: bool, workers: int,
           progress: bool = True) -> tuple[list[dict], list[tuple[str, str]]]:
    jobs: list[dict] = []
    errors: list[tuple[str, str]] = []
    done = 0
    progress = progress and sys.stderr.isatty()  # \r is noise in a pipe or log
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(scrape_one, c, deep): c
                for c in by_expected_cost(companies)}
        for fut in concurrent.futures.as_completed(futs):
            c, got, err = fut.result()
            done += 1
            if err:
                errors.append((board_label(c), err))
            else:
                jobs.extend(got)
            if progress:
                status = f"!{err}" if err else f"{len(got)} roles"
                print(f"\r  [{done}/{len(companies)}] "
                      f"{board_label(c):<28.28} {status:<28.28}",
                      end="", file=sys.stderr, flush=True)
    if progress:
        print("\r" + " " * 74 + "\r", end="", file=sys.stderr)
    return jobs, errors


# ─────────────────────────────── output ──────────────────────────────

FIELDS = ["company", "title", "short_title", "location", "city", "country", "continent",
          "link_status",
          "level", "posted", "department", "url"]


def render_table(rows: list[dict]) -> str:
    if not rows:
        return "no matching roles"
    cols = ["company", "short_title", "location_display", "level", "posted"]
    width = {c: max(len(c), max(len(str(r.get(c, ""))) for r in rows)) for c in cols}
    width["short_title"] = min(width["short_title"], 52)
    width["location_display"] = min(width["location_display"], 26)

    def line(vals, pad="│"):
        return " ".join(f"{str(v)[:width[c]]:<{width[c]}}" for c, v in zip(cols, vals))

    out = [line([c.replace("_display", "").replace("short_", "").upper()
                 for c in cols]),
           "─" * (sum(width.values()) + len(cols) - 1)]
    last = None
    for r in rows:
        vals = [r.get(c, "") for c in cols]
        if r["company"] == last:      # quieter repeated company column
            vals[0] = ""
        last = r["company"]
        out.append(line(vals))
    return "\n".join(out)


def write_out(rows: list[dict], path: str, fmt: str) -> None:
    if fmt == "csv":
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=FIELDS, extrasaction="ignore")
            w.writeheader()
            w.writerows(rows)
    elif fmt == "json":
        with open(path, "w") as f:
            json.dump(rows, f, indent=2)
    elif fmt == "md":
        with open(path, "w") as f:
            f.write("| Company | Role | Location | Level | Posted | Link |\n")
            f.write("|---|---|---|---|---|---|\n")
            for r in rows:
                title = str(r["title"]).replace("|", "\\|")
                where = r.get("location_display") or r["location"]
                f.write(f"| {r['company']} | {title} | {where} | "
                        f"{r['level']} | {r['posted']} | [apply]({r['url']}) |\n")


# ──────────────────────────── seen-state ─────────────────────────────

def job_key(j: dict) -> str:
    """Identity for tracking and the seen list.

    The URL, because it is the only thing separating two postings a firm makes
    under the same title in the same city: Jane Street's London "Software
    Engineer" exists as both a Summer Internship and a Full-Time New Grad role.
    """
    return j.get("url") or legacy_key(j)


def legacy_key(j: dict) -> str:
    """What job_key used to be, kept so old state still matches."""
    return f"{j['company']}|{j['title']}|{j['location']}".lower()


def dedup_key(j: dict) -> str:
    """Identity for de-duplication only — tracking stays on job_key().

    Citadel and Citadel Securities are separate firms sharing one careers
    platform, and they cross-list their campus programmes: 22 of the 23
    early-career roles they have in common sit at the same path on both hosts.
    That is one job posted twice, so the host is dropped and the pair collapses.
    """
    url = j.get("url") or ""
    for host in ("//www.citadel.com/", "//www.citadelsecurities.com/"):
        if host in url:
            return "citadel|" + url.split(host, 1)[1]
    return job_key(j)


def load_seen() -> dict:
    return load_json(SEEN_FILE, default={})


def tracked_keys(status: str) -> set:
    """Job keys the Mac app has marked with a given status."""
    data = load_json(TRACKED_FILE, default={})
    return {k for k, v in data.items()
            if isinstance(v, dict) and v.get("status") == status}


def save_seen(seen: dict) -> None:
    with open(SEEN_FILE, "w") as f:
        json.dump(seen, f, indent=0)


# ─────────────────────────────── commands ────────────────────────────

def is_configured(c: dict) -> bool:
    """A placeholder entry has an ats but nothing to point it at."""
    ats = c.get("ats", "")
    if ats == "workday":
        return all(c.get(k) for k in ("host", "tenant", "site"))
    if ats == "eightfold":
        return bool(c.get("host") and c.get("tenant"))
    if ats == "sitemap":
        return bool(c.get("host") and c.get("sitemap"))
    if ats in ("jibe", "citadel"):
        return bool(c.get("host"))
    if ats in ("amazon", "uber", "wolverine", "optiver", "twosigma",
               "simplify", "janestreet"):
        return True          # nothing to configure
    return bool(c.get("token"))


def enabled_companies(cfg: dict, only: list[str] | None,
                      tags: list[str] | None) -> list[dict]:
    out = []
    for c in cfg["companies"]:
        # Enabled but unconfigured buys a guaranteed failure every run.
        if not c.get("enabled", True) or not is_configured(c):
            continue
        if only and not any(o.lower() in c["name"].lower() for o in only):
            continue
        if tags and not set(t.lower() for t in tags) & set(
                t.lower() for t in c.get("tags", [])):
            continue
        out.append(c)
    return out


def cmd_scrape(args) -> int:
    cfg = load_json(COMPANIES_FILE)
    cats = build_category_matchers(load_json(CATEGORIES_FILE))

    if args.category not in cats:
        sys.exit(f"unknown category '{args.category}'. "
                 f"available: {', '.join(sorted(cats))}")

    firms = enabled_companies(cfg, args.company, args.tag)
    if not firms:
        sys.exit("no companies selected")

    print(f"scraping {len(firms)} firms  ·  category={args.category}  "
          f"·  level={args.level}", file=sys.stderr)
    raw, errors = scrape(firms, args.deep, args.workers)

    raw_cats = load_json(CATEGORIES_FILE)
    unwanted_stacks = {t.strip().lower() for t in (args.no_stack or [])}
    unknown = unwanted_stacks - set(stack_names(raw_cats))
    if unknown:
        sys.exit(f"unknown stack(s): {', '.join(sorted(unknown))}. available: "
                 + ", ".join(sorted(stack_names(raw_cats))))

    rows = []
    for j in raw:
        if not classify(j, cats[args.category], args.level, args.deep):
            continue
        if not passes_stacks(j, unwanted_stacks, raw_cats, cats, args.deep):
            continue

        places = parse_locations(j.get("location"))
        j["places"] = places
        j["location_display"] = format_location(places, j.get("location", ""))
        j["city"] = "; ".join(dict.fromkeys(p["city"] for p in places if p["city"]))
        j["country"] = "; ".join(dict.fromkeys(p["country"] for p in places if p["country"]))
        j["continent"] = "; ".join(dict.fromkeys(p["continent"] for p in places if p["continent"]))

        if args.location:
            hay = f"{j.get('location') or ''} {j['location_display']} {j['country']}".lower()
            if not any(l.lower() in hay for l in args.location):
                continue
        if args.continent:
            want = {c.strip().lower() for c in args.continent}
            if not any(p["continent"].lower() in want for p in places):
                continue
        if args.city:
            want = [c.strip().lower() for c in args.city]
            if not any(w in p["city"].lower() for p in places for w in want):
                continue

        j["level"] = detect_level(j) or "-"
        j["short_title"] = short_title(j.get("title", ""))
        rows.append(j)

    # De-duplicate, then sort newest-first with undated roles last. job_key is
    # the URL where there is one, so two postings a firm makes under the same
    # title in the same city stay two rows.
    # Sorted by company first so a cross-listed posting always collapses to the
    # same survivor, rather than whichever board happened to answer first.
    uniq, seen_keys = [], set()
    for r in sorted(rows, key=lambda x: x["company"]):
        k = dedup_key(r)
        if k not in seen_keys:
            seen_keys.add(k)
            uniq.append(r)
    rows = sorted(uniq, key=lambda r: (r["posted"] == "", r["posted"], r["company"]),
                  reverse=False)
    rows.sort(key=lambda r: (r["posted"] == "", "" if r["posted"] == "" else r["posted"]),
              reverse=True)

    if args.since:
        cutoff = (dt.date.today() - dt.timedelta(days=args.since)).isoformat()
        rows = [r for r in rows if r["posted"] and r["posted"] >= cutoff]

    if args.skip_hidden:
        hidden = tracked_keys("hidden")
        rows = [r for r in rows if job_key(r) not in hidden
                and legacy_key(r) not in hidden]
    if args.saved_only:
        saved = tracked_keys("favorite")
        rows = [r for r in rows if job_key(r) in saved or legacy_key(r) in saved]

    seen = load_seen()
    # The legacy key too, so the run after the key changed doesn't announce
    # every posting as new.
    fresh = [r for r in rows if job_key(r) not in seen and legacy_key(r) not in seen]
    if args.new_only:
        rows = fresh
    if not args.no_state:
        today = dt.date.today().isoformat()
        for r in rows:
            seen.setdefault(job_key(r), today)
        save_seen(seen)

    if args.format == "table" and not args.out:
        print(render_table(rows))
    elif args.out:
        write_out(rows, args.out, args.format if args.format != "table" else "csv")
        print(f"wrote {len(rows)} roles → {args.out}")
    else:
        json.dump(rows, sys.stdout, indent=2)
        print()

    print(f"\n{len(rows)} roles across {len({r['company'] for r in rows})} firms"
          f"  ({len(fresh)} not seen before)", file=sys.stderr)
    if errors:
        print(f"{len(errors)} board(s) failed:", file=sys.stderr)
        for name, err in errors:
            print(f"  - {name}: {err}", file=sys.stderr)
    return 0


def cmd_companies(args) -> int:
    cfg = load_json(COMPANIES_FILE)
    for c in cfg["companies"]:
        flag = " " if c.get("enabled", True) else "×"
        tags = ",".join(c.get("tags", []))
        ident = c.get("token") or c.get("host") or c.get("tenant", "")
        # A firm with more than one board gets one line per board, so say which.
        label = f"{c['name']} · {c['board']}" if c.get("board") else c["name"]
        print(f"{flag} {label:<26.26} {c['ats']:<16} {ident:<28.28} {tags}")
    n = sum(1 for c in cfg["companies"] if c.get("enabled", True))
    print(f"\n{n} enabled / {len(cfg['companies'])} total"
          f"   (× = disabled; edit {os.path.basename(COMPANIES_FILE)})")
    return 0


def cmd_categories(args) -> int:
    for name, spec in load_json(CATEGORIES_FILE).items():
        print(f"\n{name}\n  {spec.get('description','')}")
        print(f"  matches: {', '.join(spec.get('include', [])[:10])}"
              + (" …" if len(spec.get("include", [])) > 10 else ""))
    print(f"\nedit {os.path.basename(CATEGORIES_FILE)} to change these")
    return 0


def cmd_verify(args) -> int:
    cfg = load_json(COMPANIES_FILE)
    firms = cfg["companies"] if args.all else [
        c for c in cfg["companies"] if c.get("enabled", True)]
    skipped = len(cfg["companies"]) - len(firms)
    ok = bad = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(scrape_one, c, False): c for c in firms}
        for fut in concurrent.futures.as_completed(futs):
            c, jobs, err = fut.result()
            if err:
                bad += 1
                print(f"  FAIL  {board_label(c):<26.26} {c.get('ats','')}/"
                      f"{c.get('token', c.get('tenant',''))}  → {err}")
            else:
                ok += 1
                print(f"  ok    {board_label(c):<26.26} {len(jobs):>4} roles")
    msg = f"\n{ok} working, {bad} broken"
    if skipped:
        msg += f", {skipped} disabled (use --all to test those too)"
    print(msg)
    return 1 if bad else 0


ATS_PATTERNS = [
    ("greenhouse",
     r"(?:boards|job-boards)\.greenhouse\.io/(?:embed/job_board\?for=)?([a-zA-Z0-9_-]+)"),
    ("greenhouse", r"for=([a-zA-Z0-9_]+)"),
    ("lever", r"jobs\.lever\.co/([a-zA-Z0-9_-]+)"),
    ("ashby", r"jobs\.ashbyhq\.com/([a-zA-Z0-9_-]+)"),
    ("smartrecruiters", r"smartrecruiters\.com/(?:v1/companies/)?([a-zA-Z0-9_-]+)"),
    ("workday", r"([a-z0-9-]+\.wd\d+\.myworkdayjobs\.com)"),
]


def cmd_discover(args) -> int:
    """Sniff a careers page for its ATS so you can add the firm to companies.json."""
    try:
        html = http(args.url).decode("utf-8", "replace")
    except FetchError as e:
        print(f"could not fetch {args.url}: {e}", file=sys.stderr)
        if "403" in str(e):
            print("The site is blocking scripted requests. Open the page in a browser,\n"
                  "View Source, and search for 'greenhouse', 'lever', 'ashby' or\n"
                  "'myworkdayjobs' to find the token by hand.", file=sys.stderr)
        return 1

    found: dict[str, set] = {}
    for ats, pat in ATS_PATTERNS:
        for m in re.finditer(pat, html):
            tok = m.group(1)
            if tok.lower() in {"embed", "job_board", "v1", "www", "jobs"}:
                continue
            found.setdefault(ats, set()).add(tok)

    if not found:
        print("No ATS fingerprint in the raw HTML.")
        print("The board is probably rendered client-side. Open the careers page,")
        print("check DevTools → Network → Fetch/XHR, and look for a JSON request.")
        return 1

    print(f"Found in {args.url}:\n")
    for ats, toks in found.items():
        for t in sorted(toks):
            print(f"  {ats:<16} {t}")
            if ats == "workday":
                print('    → {"name": "…", "ats": "workday", "host": "%s",\n'
                      '       "tenant": "…", "site": "…", "enabled": true}' % t)
            else:
                print('    → {"name": "…", "ats": "%s", "token": "%s", "enabled": true}'
                      % (ats, t))
    print(f"\nPaste the winning line into {os.path.basename(COMPANIES_FILE)}, "
          f"then run:  ./quantjobs.py verify")
    return 0


# ─────────────────────────────── cli ─────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(
        prog="quantjobs",
        description="Scrape internship / new-grad roles from quant firm job boards.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  ./quantjobs.py scrape --category swe
  ./quantjobs.py scrape --category quant-trading --level intern
  ./quantjobs.py scrape --category swe --location london --out london.csv
  ./quantjobs.py scrape --category quant-research --new-only
  ./quantjobs.py companies
  ./quantjobs.py discover https://www.somefirm.com/careers
""")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scrape", help="fetch and filter postings")
    s.add_argument("--category", "-c", default="swe",
                   help="category to filter on (see: quantjobs.py categories)")
    s.add_argument("--level", "-l", default="intern",
                   choices=["intern", "newgrad", "intern-or-newgrad", "any"],
                   help="seniority filter (default: intern)")
    s.add_argument("--location", "-L", action="append",
                   help="substring match on location; repeatable")
    s.add_argument("--continent", action="append",
                   help="Europe | Asia | North America | …; repeatable")
    s.add_argument("--city", action="append",
                   help="match a parsed city name; repeatable")
    s.add_argument("--company", action="append",
                   help="limit to firms matching this name; repeatable")
    s.add_argument("--tag", action="append",
                   help="limit to firms carrying this tag; repeatable")
    s.add_argument("--since", type=int, metavar="DAYS",
                   help="only roles posted in the last N days")
    s.add_argument("--new-only", action="store_true",
                   help="only roles not seen on a previous run")
    s.add_argument("--skip-hidden", action="store_true",
                   help="drop roles hidden in the Mac app")
    s.add_argument("--saved-only", action="store_true",
                   help="only roles saved in the Mac app")
    s.add_argument("--no-state", action="store_true",
                   help="don't record this run in .seen.json")
    s.add_argument("--deep", action="store_true",
                   help="also match against full descriptions (slower)")
    s.add_argument("--no-stack", action="append", metavar="STACK",
                   help="leave out roles using this stack; repeatable. "
                        "cpp | python | frontend. Roles that name no stack are "
                        "always kept — that's most of them")
    s.add_argument("--format", "-f", default="table",
                   choices=["table", "csv", "json", "md"])
    s.add_argument("--out", "-o", help="write to file instead of stdout")
    s.add_argument("--workers", "-w", type=int, default=8)
    s.set_defaults(fn=cmd_scrape)

    c = sub.add_parser("companies", help="list configured firms")
    c.set_defaults(fn=cmd_companies)

    k = sub.add_parser("categories", help="list configured categories")
    k.set_defaults(fn=cmd_categories)

    v = sub.add_parser("verify", help="check every board still resolves")
    v.add_argument("--all", action="store_true",
                   help="also test disabled entries")
    v.add_argument("--workers", "-w", type=int, default=8)
    v.set_defaults(fn=cmd_verify)

    d = sub.add_parser("discover", help="find a firm's ATS from its careers URL")
    d.add_argument("url")
    d.set_defaults(fn=cmd_discover)

    args = p.parse_args()
    try:
        return args.fn(args)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
