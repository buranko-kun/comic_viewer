import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse, parse_qs
import time
import re
import sys

# ============================================================
# CONFIG
# ============================================================

BASE_URL = "https://getcomics.org/sitemap/"

START_PAGE = 1

# None = automatically discover the last sitemap page
MAX_PAGES = None

# Seconds between requests
DELAY = 1.5

OUTPUT_FILE = "getcomics_post_links.txt"

REQUEST_TIMEOUT = 20

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    )
}


# ============================================================
# COLORS
# ============================================================

RESET = "\033[0m"
BOLD = "\033[1m"

GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
CYAN = "\033[96m"
BLUE = "\033[94m"
MAGENTA = "\033[95m"
WHITE = "\033[97m"
GRAY = "\033[90m"


# Enable ANSI colors on Windows
if sys.platform == "win32":
    try:
        import colorama
        colorama.init()
    except ImportError:
        pass


# ============================================================
# HELPERS
# ============================================================

def format_time(seconds):

    if seconds < 60:
        return f"{seconds:.1f}s"

    minutes = int(seconds // 60)
    secs = int(seconds % 60)

    if minutes < 60:
        return f"{minutes}m {secs}s"

    hours = int(minutes // 60)
    minutes = int(minutes % 60)

    return f"{hours}h {minutes}m"


def progress_bar(current, total, width=30):

    if total <= 0:
        return ""

    percentage = min(current / total, 1.0)

    filled = int(width * percentage)

    bar = "█" * filled + "░" * (width - filled)

    return (
        f"{CYAN}[{bar}]{RESET} "
        f"{percentage * 100:6.2f}%"
    )


def print_header():

    print()

    print(
        f"{CYAN}{BOLD}"
        "╔══════════════════════════════════════════════════════╗"
        f"{RESET}"
    )

    print(
        f"{CYAN}{BOLD}"
        "║              📚 GETCOMICS SCRAPER                  ║"
        f"{RESET}"
    )

    print(
        f"{CYAN}{BOLD}"
        "╚══════════════════════════════════════════════════════╝"
        f"{RESET}"
    )

    print()


# ============================================================
# SITEMAP PAGE URL
# ============================================================

def get_page_url(page_num):

    if page_num == 1:
        return BASE_URL

    return f"{BASE_URL}?lcp_page0={page_num}"


# ============================================================
# FETCH PAGE
# ============================================================

def fetch_page(page_num):

    url = get_page_url(page_num)

    try:

        response = requests.get(
            url,
            headers=HEADERS,
            timeout=REQUEST_TIMEOUT
        )

        response.raise_for_status()

        return response.text

    except requests.exceptions.Timeout:

        print(
            f"{RED}❌ Timeout{RESET}"
        )

        return None

    except requests.exceptions.HTTPError as e:

        print(
            f"{RED}❌ HTTP error: {e}{RESET}"
        )

        return None

    except requests.exceptions.RequestException as e:

        print(
            f"{RED}❌ Request error: {e}{RESET}"
        )

        return None


# ============================================================
# FIND LAST PAGE
# ============================================================

def discover_last_page(html):

    """
    Looks for pagination links such as:

        ?lcp_page0=2
        ?lcp_page0=3
        ...
        ?lcp_page0=230

    Returns the highest page number found.
    """

    soup = BeautifulSoup(
        html,
        "html.parser"
    )

    page_numbers = []

    for a in soup.find_all("a", href=True):

        href = a["href"]

        # Look specifically for lcp_page0
        match = re.search(
            r"[?&]lcp_page0=(\d+)",
            href
        )

        if match:

            page_number = int(
                match.group(1)
            )

            page_numbers.append(
                page_number
            )

    if not page_numbers:
        return 1

    return max(page_numbers)


# ============================================================
# DETERMINE IF URL IS A POST
# ============================================================

def is_post_url(url):

    """
    GetComics post URLs appear to use a structure like:

        https://getcomics.org/dc/comic-name/
        https://getcomics.org/marvel/comic-name/
        https://getcomics.org/other-comics/comic-name/

    We deliberately allow any category.
    """

    parsed = urlparse(url)

    # Must be GetComics
    if parsed.netloc.lower() not in {
        "getcomics.org",
        "www.getcomics.org"
    }:
        return False

    path = parsed.path.strip("/")

    if not path:
        return False

    # Ignore known non-post paths
    ignored_first_parts = {
        "sitemap",
        "wp-admin",
        "wp-content",
        "wp-includes",
        "wp-json",
        "author",
        "tag",
        "category",
        "search",
        "feed",
        "support",
        "dmca",
        "contact",
        "about",
    }

    first_part = path.split("/")[0].lower()

    if first_part in ignored_first_parts:
        return False

    # Ignore WordPress files
    if path.endswith(".xml"):
        return False

    if path.endswith(".php"):
        return False

    # Need at least:
    #
    # /category/post/
    #
    parts = [
        part
        for part in path.split("/")
        if part
    ]

    if len(parts) < 2:
        return False

    return True


# ============================================================
# EXTRACT POSTS
# ============================================================

def extract_post_links(html):

    soup = BeautifulSoup(
        html,
        "html.parser"
    )

    all_anchors = soup.find_all(
        "a",
        href=True
    )

    post_links = set()

    for a in all_anchors:

        href = a.get("href", "").strip()

        if not href:
            continue

        # Convert relative URLs
        full_url = urljoin(
            BASE_URL,
            href
        )

        # Remove query strings
        parsed = urlparse(full_url)

        clean_url = (
            f"{parsed.scheme}://"
            f"{parsed.netloc}"
            f"{parsed.path}"
        )

        # Normalize trailing slash
        clean_url = clean_url.rstrip("/") + "/"

        if is_post_url(clean_url):

            post_links.add(clean_url)

    return post_links, len(all_anchors)


# ============================================================
# MAIN
# ============================================================

def main():

    print_header()

    print(
        f"{WHITE}🌐 Target:{RESET} "
        f"{CYAN}{BASE_URL}{RESET}"
    )

    print(
        f"{WHITE}📄 Pagination:{RESET} "
        f"{CYAN}?lcp_page0=X{RESET}"
    )

    print(
        f"{WHITE}⏱️  Request delay:{RESET} "
        f"{DELAY}s"
    )

    print(
        f"{WHITE}💾 Output:{RESET} "
        f"{OUTPUT_FILE}"
    )

    print()

    print(
        f"{GRAY}{'─' * 65}{RESET}"
    )

    print()

    # --------------------------------------------------------
    # FIRST PAGE
    # --------------------------------------------------------

    print(
        f"{CYAN}🔎 Inspecting sitemap pagination...{RESET}"
    )

    start_time = time.time()

    first_html = fetch_page(1)

    if first_html is None:

        print(
            f"{RED}❌ Could not fetch the sitemap.{RESET}"
        )

        return

    discovered_last_page = discover_last_page(
        first_html
    )

    print(
        f"{GREEN}✓{RESET} Sitemap reports "
        f"{BOLD}{discovered_last_page}{RESET} pages."
    )

    print()

    # --------------------------------------------------------
    # Determine max pages
    # --------------------------------------------------------

    if MAX_PAGES is None:

        total_pages = discovered_last_page

    else:

        total_pages = min(
            MAX_PAGES,
            discovered_last_page
        )

    print(
        f"{WHITE}📄 Pages to scrape:{RESET} "
        f"{BOLD}{total_pages}{RESET}"
    )

    print()

    print(
        f"{GRAY}{'─' * 65}{RESET}"
    )

    print()

    # --------------------------------------------------------
    # Counters
    # --------------------------------------------------------

    all_links = set()

    pages_scraped = 0
    pages_failed = 0

    total_raw_links = 0
    total_posts_found = 0

    previous_page_links = None
    repeated_pages = 0

    # --------------------------------------------------------
    # SCRAPE PAGES
    # --------------------------------------------------------

    for page in range(
        START_PAGE,
        total_pages + 1
    ):

        page_start = time.time()

        print(
            f"{BOLD}📄 Page {page}/{total_pages}{RESET} "
            f"{progress_bar(page, total_pages)} ",
            end="",
            flush=True
        )

        # ----------------------------------------------------
        # Use first page we already downloaded
        # ----------------------------------------------------

        if page == 1:

            html = first_html

        else:

            html = fetch_page(page)

        # ----------------------------------------------------
        # Request failed
        # ----------------------------------------------------

        if html is None:

            pages_failed += 1

            print(
                f"{RED}❌ FAILED{RESET}"
            )

            # Continue to next page
            time.sleep(DELAY)

            continue

        # ----------------------------------------------------
        # Extract links
        # ----------------------------------------------------

        links, raw_count = extract_post_links(
            html
        )

        page_time = (
            time.time() - page_start
        )

        total_raw_links += raw_count

        total_posts_found += len(links)

        pages_scraped += 1

        # ----------------------------------------------------
        # New links
        # ----------------------------------------------------

        new_links = (
            links - all_links
        )

        all_links.update(
            links
        )

        # ----------------------------------------------------
        # Detect duplicate page
        # ----------------------------------------------------

        if previous_page_links == links:

            repeated_pages += 1

        else:

            repeated_pages = 0

        previous_page_links = links

        # ----------------------------------------------------
        # Output
        # ----------------------------------------------------

        print(
            f"{GREEN}✓{RESET} "
            f"{len(links):>4} posts "
            f"{GRAY}|{RESET} "
            f"{GREEN}+{len(new_links):>4} new{RESET} "
            f"{GRAY}|{RESET} "
            f"📚 Total: "
            f"{BOLD}{len(all_links):,}{RESET} "
            f"{GRAY}| {page_time:.1f}s{RESET}"
        )

        # ----------------------------------------------------
        # Safety check
        # ----------------------------------------------------

        if repeated_pages >= 3:

            print()

            print(
                f"{YELLOW}"
                "⚠️ The last 3 pages were identical."
                f"{RESET}"
            )

            print(
                f"{YELLOW}"
                "The server may be repeating pages. "
                "Stopping."
                f"{RESET}"
            )

            break

        # ----------------------------------------------------
        # Delay
        # ----------------------------------------------------

        if page < total_pages:

            time.sleep(DELAY)

    # ========================================================
    # SAVE
    # ========================================================

    print()

    print(
        f"{GRAY}{'─' * 65}{RESET}"
    )

    print()

    print(
        f"{CYAN}"
        f"💾 Saving {len(all_links):,} unique URLs..."
        f"{RESET}"
    )

    sorted_links = sorted(
        all_links
    )

    try:

        with open(
            OUTPUT_FILE,
            "w",
            encoding="utf-8"
        ) as file:

            for link in sorted_links:

                file.write(
                    link + "\n"
                )

    except OSError as e:

        print()

        print(
            f"{RED}"
            f"❌ Failed to save file: {e}"
            f"{RESET}"
        )

        return

    # ========================================================
    # FINAL SUMMARY
    # ========================================================

    elapsed = (
        time.time() - start_time
    )

    print()

    print(
        f"{GREEN}{BOLD}"
        "╔══════════════════════════════════════════════════════╗"
        f"{RESET}"
    )

    print(
        f"{GREEN}{BOLD}"
        "║                  ✅ SCRAPING DONE                  ║"
        f"{RESET}"
    )

    print(
        f"{GREEN}{BOLD}"
        "╚══════════════════════════════════════════════════════╝"
        f"{RESET}"
    )

    print()

    print(
        f"📄 Pages scraped:      "
        f"{BOLD}{pages_scraped:,}{RESET}"
    )

    print(
        f"❌ Failed pages:       "
        f"{BOLD}{pages_failed:,}{RESET}"
    )

    print(
        f"🔗 Raw links examined: "
        f"{BOLD}{total_raw_links:,}{RESET}"
    )

    print(
        f"🔎 Post links found:    "
        f"{BOLD}{total_posts_found:,}{RESET}"
    )

    print(
        f"✨ Unique post URLs:    "
        f"{GREEN}{BOLD}{len(sorted_links):,}{RESET}"
    )

    print(
        f"⏱️  Total time:          "
        f"{BOLD}{format_time(elapsed)}{RESET}"
    )

    print(
        f"💾 Output file:         "
        f"{BOLD}{OUTPUT_FILE}{RESET}"
    )

    print()

    if len(sorted_links) >= 7000:

        print(
            f"{GREEN}{BOLD}"
            f"🎉 Success! "
            f"Collected {len(sorted_links):,} unique posts!"
            f"{RESET}"
        )

    elif len(sorted_links) >= 5000:

        print(
            f"{YELLOW}{BOLD}"
            f"👍 Good! "
            f"Collected {len(sorted_links):,} unique posts."
            f"{RESET}"
        )

    else:

        print(
            f"{YELLOW}"
            f"⚠️ Only {len(sorted_links):,} unique posts collected."
            f"{RESET}"
        )

    print()


# ============================================================
# RUN
# ============================================================

if __name__ == "__main__":
    main()