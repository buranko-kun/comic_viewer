import json
import re
import sys
import time
from pathlib import Path
from typing import Optional, List, Dict
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup, Tag


# ============================================================
# CONFIGURATION
# ============================================================

# ------------------------------------------------------------
# PUT YOUR TXT FILE PATH HERE
# ------------------------------------------------------------

URLS_FILE = "urls.txt"

# ------------------------------------------------------------
# OUTPUT JSON FILE
# ------------------------------------------------------------

OUTPUT_FILE = "getcomics.json"

# ------------------------------------------------------------
# ERROR / PROBLEM LOG FILE
# ------------------------------------------------------------

ERROR_LOG_FILE = "getcomics_errors.txt"

# ------------------------------------------------------------
# LINK RANGE (1-based, inclusive)
#
# Example:
#   RANGE_START = 1
#   RANGE_END = 5000
#
# None = go to the last URL
# ------------------------------------------------------------

RANGE_START = 1
RANGE_END = None

# ------------------------------------------------------------
# SAVE EVERY N COMICS
# ------------------------------------------------------------

SAVE_EVERY = 2500

# ------------------------------------------------------------
# SERVER NAME
# ------------------------------------------------------------

SERVER_NAME = "GetComics Server"

# ------------------------------------------------------------
# REQUEST SETTINGS
# ------------------------------------------------------------

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/150.0.0.0 Safari/537.36"
    )
}

REQUEST_TIMEOUT = 25

# Seconds to wait between successful requests
DELAY_BETWEEN_REQUESTS = 3.0

# Extra seconds to wait when a 429 is received
DELAY_ON_429 = 15.0

# How many times to retry a URL
MAX_RETRIES = 3


# ============================================================
# KNOWN MIRROR HOSTS
# ============================================================

KNOWN_MIRROR_HOSTS = {
    # GetComics / direct
    "getcomics.info": "GetComics",
    "getcomics.org": "GetComics",

    # Original mirrors
    "terabox": "TeraBox",
    "vikingfile": "VikingFile",
    "pixeldrain": "PixelDrain",
    "datanodes": "DataNodes",
    "mediafire": "MediaFire",
    "mega": "MEGA",

    # Common on GetComics
    "ufile": "UFILE",
    "dropapk": "DropAPK",
    "zippyshare": "ZippyShare",
    "1fichier": "1Fichier",
    "anonfiles": "AnonFiles",
    "gofile": "GoFile",
    "krakenfiles": "KrakenFiles",
    "workupload": "WorkUpload",
    "uploadhaven": "UploadHaven",
    "sendspace": "SendSpace",
    "rapidgator": "RapidGator",
    "nitroflare": "NitroFlare",
    "uploaded": "Uploaded",
    "turbobit": "TurboBit",
    "ddownload": "DDownload",
    "filefactory": "FileFactory",
    "userscloud": "UsersCloud",
    "clicknupload": "ClicknUpload",
    "katfile": "KatFile",
    "keep2share": "Keep2Share",
    "k2s": "Keep2Share",
    "mexa": "MexaShare",
    "fboom": "FBoom",
    "filerio": "FileRio",
    "uptobox": "Uptobox",
    "ddl.to": "DDL.to",
    "mirrored.to": "Mirrored.to",
    "multiup": "MultiUp",
}


# ============================================================
# GETCOMICS DOWNLOAD LINKS
# ============================================================

# GetComics own download redirector
GETCOMICS_DLS_RE = re.compile(
    r"https?://(?:www\.)?getcomics\.org/dls/",
    re.IGNORECASE,
)

# Direct GetComics file servers
GETCOMICS_DIRECT_HOSTS = {
    "getcomics.info",
    "light.getcomics.info",
}

# File extensions that strongly indicate a downloadable comic/archive
DOWNLOAD_EXTENSIONS = (
    ".zip",
    ".cbz",
    ".cbr",
    ".rar",
    ".7z",
    ".pdf",
    ".tar",
    ".gz",
)


# ============================================================
# SECTION DETECTION
# ============================================================

# Matches:
#   Free Comics Download
#   Free Comic Download
#   Free DC Comic Download
#   Free Marvel Comics Download
#   Free Download
DOWNLOAD_HEADING_RE = re.compile(
    r"^\s*(?:The\s+)?Free\s+(?:[A-Za-z0-9]+\s+)*Comics?\s+Download\s*$"
    r"|^\s*(?:The\s+)?Free\s+Download\s*$",
    re.IGNORECASE,
)

STOP_SECTION_RE = re.compile(
    r"^\s*Notes?\s*:?\s*$",
    re.IGNORECASE,
)


# ============================================================
# HELPERS
# ============================================================

def normalize_text(text: str) -> str:
    """Normalize whitespace."""
    return re.sub(r"\s+", " ", text or "").strip()


def clean_url(url: str) -> str:
    """
    Clean a URL without destroying its path/query.

    Only removes surrounding whitespace.
    """
    return (url or "").strip()


def get_hostname(url: str) -> str:
    """Return lowercase hostname without www."""
    try:
        parsed = urlparse(url)
        return re.sub(
            r"^www\.",
            "",
            (parsed.netloc or "").lower(),
        )
    except ValueError:
        return ""


def is_getcomics_dls_url(url: str) -> bool:
    """Check for GetComics /dls/ redirect links."""
    return bool(GETCOMICS_DLS_RE.search(url or ""))


def is_direct_getcomics_file(url: str) -> bool:
    """
    Check whether the URL is hosted directly by GetComics
    and looks like a downloadable file.
    """
    try:
        parsed = urlparse(url)
        hostname = (parsed.netloc or "").lower()

        if hostname.startswith("www."):
            hostname = hostname[4:]

        if hostname not in GETCOMICS_DIRECT_HOSTS:
            return False

        path = (parsed.path or "").lower()

        return any(
            path.endswith(extension)
            for extension in DOWNLOAD_EXTENSIONS
        )

    except ValueError:
        return False


def is_download_file_url(url: str) -> bool:
    """
    Check whether a URL appears to point directly to a
    downloadable archive/file.
    """
    try:
        parsed = urlparse(url)

        path = (parsed.path or "").lower()

        return any(
            path.endswith(extension)
            for extension in DOWNLOAD_EXTENSIONS
        )

    except ValueError:
        return False


def find_mirror_host(
    url: str,
    link_text: str = "",
) -> Optional[str]:
    """
    Identify the mirror provider.

    Priority:
        1. GetComics /dls/ redirect
        2. Domain / URL
        3. Direct downloadable file
        4. Visible link text
        5. Unknown
    """

    url = clean_url(url)
    text = normalize_text(link_text).lower()

    # --------------------------------------------------------
    # 1. GetComics /dls/ redirect
    # --------------------------------------------------------

    if is_getcomics_dls_url(url):
        return "GetComics"

    # --------------------------------------------------------
    # 2. Domain / URL
    # --------------------------------------------------------

    hostname = get_hostname(url)

    if hostname:
        # Exact direct GetComics hosts
        if hostname in GETCOMICS_DIRECT_HOSTS:
            return "GetComics"

        # Known providers
        for identifier, display_name in KNOWN_MIRROR_HOSTS.items():
            if identifier in hostname:
                return display_name

    # --------------------------------------------------------
    # 3. Direct downloadable file
    # --------------------------------------------------------

    if is_download_file_url(url):
        return "Direct Download"

    # --------------------------------------------------------
    # 4. Visible link text
    # --------------------------------------------------------

    for identifier, display_name in KNOWN_MIRROR_HOSTS.items():
        if identifier in text:
            return display_name

    # Explicit text fallbacks
    if text in (
        "download now",
        "download",
        "direct download",
    ):
        return "GetComics"

    if "mega" in text:
        return "MEGA"

    if "mediafire" in text:
        return "MediaFire"

    if "ufile" in text:
        return "UFILE"

    if "dropapk" in text:
        return "DropAPK"

    if "zippyshare" in text or "zippy" in text:
        return "ZippyShare"

    return None


def is_download_heading(tag: Tag) -> bool:
    """Check whether a tag is a Free … Download heading."""

    if not isinstance(tag, Tag):
        return False

    text = normalize_text(
        tag.get_text(" ", strip=True)
    )

    return bool(
        DOWNLOAD_HEADING_RE.match(text)
    )


def is_stop_section(tag: Tag) -> bool:
    """Check whether a tag is the Notes section."""

    if not isinstance(tag, Tag):
        return False

    text = normalize_text(
        tag.get_text(" ", strip=True)
    )

    return bool(
        STOP_SECTION_RE.match(text)
    )


# ============================================================
# TITLE EXTRACTION
# ============================================================

def extract_title(
    soup: BeautifulSoup,
) -> Optional[str]:
    """Extract the comic title."""

    title_element = soup.find(
        "h1",
        class_="post-title",
    )

    if title_element:
        return title_element.get_text(
            " ",
            strip=True,
        )

    return None


# ============================================================
# SIZE EXTRACTION
# ============================================================

def extract_size(
    soup: BeautifulSoup,
) -> Optional[str]:
    """
    Extract the file size.

    Examples:
        Size : 2.4 GB
        Size: 2.4 GB
        Size : 875 MB
        Size: 875MB
    """

    page_text = soup.get_text(
        " ",
        strip=True,
    )

    page_text = re.sub(
        r"\s+",
        " ",
        page_text,
    )

    match = re.search(
        r"Size\s*:\s*"
        r"([0-9]+(?:\.[0-9]+)?\s*"
        r"(?:TB|GB|MB|KB))",
        page_text,
        re.IGNORECASE,
    )

    if match:
        return match.group(1)

    return None


# ============================================================
# COVER EXTRACTION
# ============================================================

def extract_cover(
    soup: BeautifulSoup,
) -> Optional[str]:
    """
    Extract the background image URL from
    .cover-background.
    """

    cover = soup.select_one(
        ".cover-background"
    )

    if not cover:
        return None

    style = cover.get(
        "style",
        "",
    )

    match = re.search(
        r"background-image\s*:\s*"
        r"url\(\s*['\"]?"
        r"([^'\")]+)"
        r"['\"]?\s*\)",
        style,
        re.IGNORECASE,
    )

    if match:
        return match.group(1)

    return None


# ============================================================
# MIRROR EXTRACTION
# ============================================================

def extract_mirrors(
    soup: BeautifulSoup,
) -> List[str]:
    """
    Extract download/mirror URLs.

    Improvements over the previous version:

    - Captures GetComics /dls/ links.
    - Captures light.getcomics.info direct files.
    - Captures other GetComics direct files.
    - Captures known mirror providers.
    - Captures direct downloadable files based on extension.
    - Captures unknown HTTP/HTTPS links when their
      surrounding text suggests they are download links.
    - Deduplicates URLs.
    - Stops at Notes.
    """

    # --------------------------------------------------------
    # Find the download heading
    # --------------------------------------------------------

    heading = None

    for tag in soup.find_all(True):

        if is_download_heading(tag):
            heading = tag
            break

    if heading is None:
        return []

    mirrors = []
    seen_urls = set()

    # --------------------------------------------------------
    # Walk everything after the download heading
    # --------------------------------------------------------

    for element in heading.find_all_next():

        if not isinstance(element, Tag):
            continue

        # ----------------------------------------------------
        # Stop at Notes
        # ----------------------------------------------------

        if is_stop_section(element):
            break

        # ----------------------------------------------------
        # Only inspect anchor tags
        # ----------------------------------------------------

        if element.name != "a":
            continue

        href = element.get("href")

        if isinstance(
            href,
            (list, tuple),
        ):
            href = (
                href[0]
                if href
                else None
            )

        if not href:
            continue

        href = clean_url(href)

        if not href:
            continue

        # ----------------------------------------------------
        # Ignore anchors / javascript
        # ----------------------------------------------------

        if href.startswith("#"):
            continue

        if href.lower().startswith(
            "javascript:"
        ):
            continue

        # ----------------------------------------------------
        # Only HTTP(S) URLs
        # ----------------------------------------------------

        if not href.lower().startswith(
            ("http://", "https://")
        ):
            continue

        link_text = normalize_text(
            element.get_text(
                " ",
                strip=True,
            )
        )

        # ----------------------------------------------------
        # Determine mirror type
        # ----------------------------------------------------

        host = find_mirror_host(
            url=href,
            link_text=link_text,
        )

        # ----------------------------------------------------
        # IMPORTANT:
        #
        # We no longer discard every unknown domain.
        #
        # Keep the URL if:
        #
        #   - it is a GetComics /dls/ link
        #   - it is a direct downloadable file
        #   - it is a known mirror
        #   - its text strongly suggests a download
        #
        # ----------------------------------------------------

        keep = False

        if is_getcomics_dls_url(href):
            keep = True

        elif is_direct_getcomics_file(href):
            keep = True

        elif is_download_file_url(href):
            keep = True

        elif host is not None:
            keep = True

        else:
            # Unknown domain, but potentially a download link
            text_lower = link_text.lower()

            download_words = (
                "download",
                "mirror",
                "direct",
                "server",
                "link",
                "file",
            )

            if any(
                word in text_lower
                for word in download_words
            ):
                keep = True

        if not keep:
            continue

        # ----------------------------------------------------
        # Deduplicate
        # ----------------------------------------------------

        dedup_key = re.sub(
            r"^(https?:)?//",
            "",
            href,
        ).rstrip("/").lower()

        if dedup_key in seen_urls:
            continue

        seen_urls.add(dedup_key)

        mirrors.append(href)

        # ----------------------------------------------------
        # Console feedback
        # ----------------------------------------------------

        if host:
            print(
                f"    ✓ {host}: {href}"
            )
        elif is_download_file_url(href):
            print(
                f"    ✓ Direct file: {href}"
            )
        else:
            print(
                f"    ✓ Download link: {href}"
            )

    return mirrors


# ============================================================
# ERROR LOGGING
# ============================================================

def log_error(
    message: str,
    url: str = "",
) -> None:
    """
    Append a line to the error log.

    Format:
        TIMESTAMP | URL | MESSAGE
    """

    log_path = Path(
        ERROR_LOG_FILE
    )

    log_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    timestamp = time.strftime(
        "%Y-%m-%d %H:%M:%S"
    )

    line = (
        f"{timestamp} | "
        f"{url} | "
        f"{message}\n"
    )

    with open(
        log_path,
        "a",
        encoding="utf-8",
    ) as f:

        f.write(line)


# ============================================================
# SCRAPE ONE GETCOMICS PAGE
# ============================================================

def scrape_getcomics(
    url: str,
) -> Optional[Dict]:
    """
    Scrape one GetComics page.

    Returns:
        {
            "title": "...",
            "cover": "...",
            "size": "...",
            "link": "https://getcomics.org/...",
            "mirrors": ["...", "..."]
        }

    Returns None on hard failure.
    """

    print()
    print("=" * 70)
    print("Scraping:")
    print(url)
    print("=" * 70)

    last_error = None

    for attempt in range(
        1,
        MAX_RETRIES + 1,
    ):

        try:

            response = requests.get(
                url,
                headers=HEADERS,
                timeout=REQUEST_TIMEOUT,
            )

            # ------------------------------------------------
            # Explicitly handle rate limiting
            # ------------------------------------------------

            if response.status_code == 429:

                print(
                    f"  429 Too Many Requests "
                    f"(attempt {attempt}/{MAX_RETRIES})"
                )

                last_error = (
                    "429 Too Many Requests"
                )

                if attempt < MAX_RETRIES:

                    print(
                        f"  Waiting "
                        f"{DELAY_ON_429}s "
                        f"before retry..."
                    )

                    time.sleep(
                        DELAY_ON_429
                    )

                    continue

                else:
                    break

            # ------------------------------------------------
            # HTTP errors
            # ------------------------------------------------

            response.raise_for_status()

            # ------------------------------------------------
            # Parse HTML
            # ------------------------------------------------

            soup = BeautifulSoup(
                response.text,
                "html.parser",
            )

            # ------------------------------------------------
            # Extract data
            # ------------------------------------------------

            title = extract_title(
                soup
            )

            cover = extract_cover(
                soup
            )

            size = extract_size(
                soup
            )

            mirrors = extract_mirrors(
                soup
            )

            # ------------------------------------------------
            # Print information
            # ------------------------------------------------

            print()
            print("Title :", title)
            print("Cover :", cover)
            print("Size  :", size)
            print("Link  :", url)

            print("Mirrors:")

            if mirrors:

                for mirror in mirrors:
                    print(
                        "  ",
                        mirror,
                    )

            else:

                print(
                    "   None"
                )

            # ------------------------------------------------
            # Log pages with no mirrors
            # ------------------------------------------------

            if not mirrors:

                log_error(
                    "No mirrors found",
                    url,
                )

            # ------------------------------------------------
            # Build comic object
            # ------------------------------------------------

            comic = {
                "title": title,
                "cover": cover,
                "size": size,
                "link": url,
                "mirrors": mirrors,
            }

            return comic

        # ----------------------------------------------------
        # HTTP errors
        # ----------------------------------------------------

        except requests.exceptions.HTTPError as e:

            last_error = str(e)

            print(
                f"  HTTP error "
                f"(attempt {attempt}/{MAX_RETRIES}): "
                f"{e}"
            )

            if attempt < MAX_RETRIES:

                time.sleep(
                    DELAY_ON_429
                )

                continue

            break

        # ----------------------------------------------------
        # Request errors
        # ----------------------------------------------------

        except requests.RequestException as e:

            last_error = str(e)

            print(
                f"  Request error "
                f"(attempt {attempt}/{MAX_RETRIES}): "
                f"{e}"
            )

            if attempt < MAX_RETRIES:

                time.sleep(
                    DELAY_ON_429
                )

                continue

            break

        # ----------------------------------------------------
        # Unexpected errors
        # ----------------------------------------------------

        except Exception as e:

            last_error = str(e)

            print(
                f"  Unexpected error: {e}"
            )

            break

    # --------------------------------------------------------
    # All retries exhausted
    # --------------------------------------------------------

    print(
        "ERROR scraping page after retries:"
    )

    print(
        last_error
    )

    log_error(
        f"FAILED: {last_error}",
        url,
    )

    return None


# ============================================================
# READ URL LIST
# ============================================================

def load_urls(
    file_path: str,
) -> List[str]:
    """
    Read URLs from a TXT file.

    One URL per line.

    Empty lines and lines starting with #
    are ignored.
    """

    path = Path(
        file_path
    )

    if not path.exists():

        print()
        print("ERROR:")
        print(
            "URL file does not exist:"
        )

        print(
            file_path
        )

        sys.exit(1)

    urls = []

    with open(
        path,
        "r",
        encoding="utf-8",
    ) as file:

        for line in file:

            line = line.strip()

            if not line:
                continue

            if line.startswith("#"):
                continue

            if not line.startswith(
                ("http://", "https://")
            ):

                print(
                    "Skipping invalid URL:",
                    line,
                )

                continue

            urls.append(line)

    return urls


# ============================================================
# SAVE JSON
# ============================================================

def save_json(
    data: Dict,
    file_path: str,
) -> None:

    output_path = Path(
        file_path
    )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with open(
        output_path,
        "w",
        encoding="utf-8",
    ) as file:

        json.dump(
            data,
            file,
            indent=2,
            ensure_ascii=False,
        )

        file.write("\n")

    print()
    print("=" * 70)
    print("JSON SAVED:")
    print(output_path)
    print("=" * 70)


# ============================================================
# RANGE HELPERS
# ============================================================

def resolve_range(
    total: int,
):

    """
    Determine the range (1-based, inclusive).

    Command line overrides config:

        python script.py START END

        python script.py START

    START only:
        END = last URL
    """

    start = RANGE_START
    end = RANGE_END

    args = sys.argv[1:]

    # --------------------------------------------------------
    # Command-line START
    # --------------------------------------------------------

    if len(args) >= 1:

        try:

            start = int(
                args[0]
            )

        except ValueError:

            print(
                "Invalid START argument:",
                args[0],
            )

            sys.exit(1)

    # --------------------------------------------------------
    # Command-line END
    # --------------------------------------------------------

    if len(args) >= 2:

        try:

            end = int(
                args[1]
            )

        except ValueError:

            print(
                "Invalid END argument:",
                args[1],
            )

            sys.exit(1)

    # --------------------------------------------------------
    # Defaults
    # --------------------------------------------------------

    if start is None:
        start = 1

    if end is None:
        end = total

    # --------------------------------------------------------
    # Clamp range
    # --------------------------------------------------------

    start = max(
        1,
        start,
    )

    end = min(
        total,
        end,
    )

    # --------------------------------------------------------
    # Validate
    # --------------------------------------------------------

    if start > end:

        print()
        print("ERROR:")

        print(
            f"START ({start}) "
            f"is greater than "
            f"END ({end})."
        )

        sys.exit(1)

    return start, end


def build_chunk_output_path(
    chunk_start: int,
    chunk_end: int,
) -> str:

    """
    Build a filename for a chunk.

    Example:

        getcomics_1001-1250.json
        getcomics_1251-1500.json
    """

    path = Path(
        OUTPUT_FILE
    )

    new_name = (
        f"{path.stem}_"
        f"{chunk_start}-"
        f"{chunk_end}"
        f"{path.suffix}"
    )

    return str(
        path.with_name(
            new_name
        )
    )


# ============================================================
# MAIN
# ============================================================

def main():

    print()
    print("=" * 70)
    print("GETCOMICS SCRAPER")
    print("=" * 70)

    # --------------------------------------------------------
    # Load URL list
    # --------------------------------------------------------

    urls = load_urls(
        URLS_FILE
    )

    if not urls:

        print()
        print(
            "No URLs found in:"
        )

        print(
            URLS_FILE
        )

        sys.exit(1)

    total = len(urls)

    print()
    print(
        "URLs found:",
        total,
    )

    # --------------------------------------------------------
    # Resolve range
    # --------------------------------------------------------

    start, end = resolve_range(
        total
    )

    urls = urls[
        start - 1:end
    ]

    print()
    print(
        f"Scraping range: "
        f"{start} - {end} "
        f"({len(urls)} URLs)"
    )

    print(
        "Error log     :",
        ERROR_LOG_FILE,
    )

    print(
        f"Save every    : "
        f"{SAVE_EVERY} comics"
    )

    print(
        f"Delay between requests: "
        f"{DELAY_BETWEEN_REQUESTS}s"
    )

    print(
        f"Delay on 429          : "
        f"{DELAY_ON_429}s"
    )

    print(
        f"Max retries           : "
        f"{MAX_RETRIES}"
    )

    # --------------------------------------------------------
    # Current batch
    # --------------------------------------------------------

    current_batch: List[Dict] = []

    batch_start_index = start

    total_saved = 0

    # --------------------------------------------------------
    # Process URLs
    # --------------------------------------------------------

    for i, url in enumerate(urls):

        absolute_index = (
            start + i
        )

        print()
        print(
            f"[{absolute_index}/{end}]"
        )

        comic = scrape_getcomics(
            url
        )

        if comic is None:

            print(
                "Skipping this URL."
            )

        else:

            current_batch.append(
                comic
            )

        # ----------------------------------------------------
        # Save every SAVE_EVERY successful comics
        # ----------------------------------------------------

        if len(current_batch) >= SAVE_EVERY:

            chunk_start = (
                batch_start_index
            )

            chunk_end = (
                absolute_index
            )

            output_file = (
                build_chunk_output_path(
                    chunk_start,
                    chunk_end,
                )
            )

            output = {
                "name": SERVER_NAME,
                "comics": current_batch,
            }

            save_json(
                output,
                output_file,
            )

            total_saved += len(
                current_batch
            )

            print(
                f"  → Batch of "
                f"{len(current_batch)} "
                f"comics saved."
            )

            print(
                f"  → Total comics "
                f"saved so far: "
                f"{total_saved}"
            )

            # ------------------------------------------------
            # Reset batch
            # ------------------------------------------------

            current_batch = []

            batch_start_index = (
                absolute_index + 1
            )

        # ----------------------------------------------------
        # Delay between requests
        # ----------------------------------------------------

        if absolute_index < end:

            time.sleep(
                DELAY_BETWEEN_REQUESTS
            )

    # --------------------------------------------------------
    # Final save
    # --------------------------------------------------------

    if current_batch:

        chunk_start = (
            batch_start_index
        )

        chunk_end = end

        output_file = (
            build_chunk_output_path(
                chunk_start,
                chunk_end,
            )
        )

        output = {
            "name": SERVER_NAME,
            "comics": current_batch,
        }

        save_json(
            output,
            output_file,
        )

        total_saved += len(
            current_batch
        )

        print(
            f"  → Final batch of "
            f"{len(current_batch)} "
            f"comics saved."
        )

    # --------------------------------------------------------
    # Done
    # --------------------------------------------------------

    print()
    print("=" * 70)
    print("DONE")
    print("=" * 70)

    print(
        f"Total comics saved: "
        f"{total_saved}"
    )

    print(
        "Check error log for problems:",
        ERROR_LOG_FILE,
    )


# ============================================================
# RUN
# ============================================================

if __name__ == "__main__":
    main()
