#!/usr/bin/env python3
"""Split the routed domain list into services, by brand.

A customer thinks in brands. They know whether they want PlayStation, not
whether they want "console gaming", and an admin ticking boxes in a panel
wants the same vocabulary. So the unit here is the brand - PlayStation, Steam,
Netflix, GitHub - and each brand holds one or more groups of domains.

Two levels, because one is not enough:

  service   PlayStation          admin decides whether it is offered at all
  group       store and online   per customer: which parts they get routed
              game downloads

The groups are what make the plans worth selling. PlayStation's store is a few
kilobytes of sign-in and licensing and is genuinely blocked; its package CDN is
tens to hundreds of GB per game and costs two bytes of paid transit for every
byte delivered, on each of the two servers. A plan that routes one and not the
other is a real product. A plan that treats "PlayStation" as one thing is not.

Groups also solve a matching problem. The package hosts are subdomains of the
names that serve the store - assets1.xboxlive.com under xboxlive.com - and
dnsmasq matches by suffix, so a single rule for the parent would swallow them.
Naming them explicitly puts them in their own group and wins the longest match.

Domains belonging to no recognisable brand fall into catch-all services at the
end, so nothing is lost and the total always reconciles.

Writes domains/services.json, stable across runs so it diffs cleanly.
"""
import io
import json
import os
import sys

# The summary it prints is half Persian, and a Windows console
# defaults to cp1252 - which turned a finished run into a traceback.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Hosts that carry game packages. Verified individually: each was seen serving
# real package data in a capture, and both consoles were watched downloading
# through them. They are listed rather than pattern-matched because they must
# out-specify the storefront rules above them.
# Groups that exist so they can be seen and chosen, never so they can happen
# by default.
OPT_IN = {"bypass.ea", "bypass.playstation", "bypass.epic",
          "bypass.azure"}

EXPLICIT = {
    "playstation.download": [
        "gst.prod.dl.playstation.net",
        "ps5cel.np.dl.playstation.net",
        "uef.np.dl.playstation.net",
        "zeus.dl.playstation.net",
    ],
    # Epic's game backend. Routing these breaks Fortnite matchmaking: the game
    # server ignores gameplay packets that arrive from an address other than
    # the one matchmaking came from. They are in the catalogue so an operator
    # can see them and decide, and marked opt-in below so that deciding
    # nothing leaves them alone. Same list epic-pin works from.
    "bypass.epic": ['account-public-service-prod.ol.epicgames.com', 'datarouter.ol.epicgames.com', 'launcher-public-service-prod06.ol.epicgames.com', 'links-public-service-live.ol.epicgames.com', 'events-public-service-live.ol.epicgames.com', 'datastorage-public-service-live.ol.epicgames.com', 'data-asset-directory-public-service-prod.ol.epicgames.com', 'fortnitecontent-website-prod07.ol.epicgames.com', 'fortnite-public-service-prod11.ol.epicgames.com', 'mcp-gc.live.fngw.ol.epicgames.com', 'gc.svc.live.fngw.ol.epicgames.com', 'ds.svc.live.fngw.ol.epicgames.com', 'fngw-svc-ds-livefn.ol.epicgames.com', 'fn-service-habanero-live-public.ogs.live.on.epicgames.com', 'fn-service-discovery-live-public.ogs.live.on.epicgames.com', 'prm-dialogue-public-api-prod.edea.live.use1a.on.epicgames.com'],
    "xbox.download": [
        "dl.delivery.mp.microsoft.com",
        "assets1.xboxlive.com",
        "xvcf1.xboxlive.com",
        "xvcf2.xboxlive.com",
        "dlassets.xboxlive.com",
    ],
}

# (service key, service label, [(group key, group label, [patterns])])
# Matched in order, first hit wins, so put the specific brands before any
# catch-all that might also match them.
BRANDS = [
    ("playstation", "PlayStation", [
        ("online", "فروشگاه، اکانت و بازی آنلاین",
         ["playstation", "pscdn", "sonyentertainment"]),
        ("download", "دانلود بازی", []),
    ]),
    ("xbox", "Xbox", [
        ("online", "فروشگاه، اکانت و بازی آنلاین",
         ["xbox", "gamepass", "mp.microsoft", "edgesuite"]),
        ("download", "دانلود بازی", []),
    ]),
    ("nintendo", "Nintendo", [("main", "همه", ["nintendo"])]),
    ("steam", "Steam", [
        ("main", "فروشگاه و انجمن", ["steampowered", "steamcommunity", "steamstatic", "valvesoftware"]),
        ("download", "دانلود بازی", ["steamcontent"]),
    ]),
    ("epic", "Epic Games", [
        ("main", "فروشگاه، لانچر و اکانت", ["epicgames", "unrealengine"]),
        # Off unless an operator deliberately turns it on - see OPT_IN.
        ("backend", "بک‌اند بازی (matchmaking فورتنایت)", []),
    ]),
    ("ea", "EA", [("main", "همه", [
        "ea.com", "easports", "eamobile", "eaplay", "eaaccess", "eacdn",
        "eaassets", "origin.com", "bioware", "respawn", "dice.se",
        "criteriongames", "frostbite", "maxis", "popcap", "swtor",
        "apexlegends", "thesims", "needforspeed", "battlefield", "fcmobile"])]),
    ("blizzard", "Blizzard / Activision", [("main", "همه", [
        "battle.net", "blizzard", "activision", "callofduty"])]),
    ("ubisoft", "Ubisoft", [("main", "همه", ["ubisoft", "ubi.com"])]),
    ("riot", "Riot Games", [("main", "همه", [
        "riotgames", "leagueoflegends", "valorant"])]),
    ("rockstar", "Rockstar", [("main", "همه", ["rockstargames", "take2games"])]),
    ("bethesda", "Bethesda", [("main", "همه", ["bethesda"])]),
    ("gog", "GOG / itch.io", [("main", "همه", ["gog.com", "itch.io", "humblebundle"])]),
    ("roblox", "Roblox", [("main", "همه", ["roblox", "rbxcdn"])]),
    ("minecraft", "Minecraft", [("main", "همه", ["minecraft", "mojang"])]),
    ("othergames", "بازی‌های دیگر", [("main", "همه", [
        "pubg", "krafton", "hoyoverse", "mihoyo", "supercell", "garena",
        "faceit", "battlecode", "unity", "vuforia", "incredibuild"])]),

    ("netflix", "Netflix", [("main", "همه", ["netflix", "nflx"])]),
    ("twitch", "Twitch", [("main", "همه", ["twitch", "ttvnw"])]),
    ("spotify", "Spotify", [("main", "همه", ["spotify", "scdn.co"])]),

    ("openai", "OpenAI / ChatGPT", [("main", "همه", [
        "openai", "chatgpt", "oaistatic", "oaiusercontent"])]),
    ("anthropic", "Claude", [("main", "همه", ["anthropic", "claude.ai"])]),
    ("otherai", "هوش مصنوعی دیگر", [("main", "همه", [
        "deepseek", "huggingface", "hf.co", "perplexity", "mistral",
        "openrouter", "groq", "together.ai", "x.ai", "ollama", "cursor",
        "codeium", "windsurf", "tensorflow", "kaggle", "deepmind"])]),

    ("github", "GitHub", [("main", "همه", ["github"])]),
    ("gitlab", "GitLab / Bitbucket", [("main", "همه", [
        "gitlab", "bitbucket", "gitpod", "gitkraken"])]),
    ("docker", "Docker / Kubernetes", [("main", "همه", [
        "docker", "quay.io", "gcr.io", "ghcr.io", "k8s.io", "kubernetes",
        "helm.sh"])]),
    ("packages", "مخازن پکیج", [("main", "همه", [
        "npmjs", "yarnpkg", "pnpm", "pypi", "rubygems", "packagist", "maven",
        "gradle", "nuget", "crates.io", "go.dev", "gopkg", "godoc", "golang",
        "jitpack", "jfrog", "bintray", "sonatype", "launchpad", "fsdn",
        "libraries.io", "packagesource", "labix", "archive.ubuntu", "centos",
        "chocolatey", "maas.io"])]),

    ("microsoft", "Microsoft / VS Code", [("main", "همه", [
        "microsoft", "visualstudio", "vscode", "aka.ms", "vsassets"])]),
    ("jetbrains", "JetBrains", [("main", "همه", ["jetbrains"])]),
    ("adobe", "Adobe", [("main", "همه", ["adobe"])]),
    ("nvidia", "NVIDIA", [("main", "همه", ["nvidia", "geforce"])]),
    ("apple", "Apple", [("main", "همه", ["apple.com"])]),
    ("google", "Google", [("main", "همه", [
        "google", "youtube", "gemini", "gstatic", "doubleclick", "admob",
        "recaptcha", "withgoogle"])]),
    ("discord", "Discord", [("main", "همه", ["discord"])]),
    ("slackzoom", "Slack / Zoom / Teams", [("main", "همه", [
        "slack", "zoom.us", "jitsi"])]),
    ("figma", "Figma / Canva / Notion", [("main", "همه", [
        "figma", "canva", "notion", "trello", "asana", "linear.app", "miro",
        "zeplin", "invis"])]),
    ("cloud", "کلاود و هاستینگ", [("main", "همه", [
        "aws.amazon", "cloudfront", "digitalocean", "linode", "heroku",
        "hetzner", "vercel", "netlify", "supabase", "render.com", "railway",
        "fly.io", "replit", "cloudflare", "appspot", "appengine", "firebase",
        "bluemix", "softlayer", "ibm.com", "zeit.co", "csb.app", "codesandbox",
        "c9.io", "es.io", "cocalc", "vmware", "virtualbox", "oracle",
        "java.com"])]),
    ("education", "آموزش و مرجع", [("main", "همه", [
        "coursera", "udemy", "edx.org", "khanacademy", "freecodecamp",
        "datacamp", "teamtreehouse", "packtpub", "coursehero", "hackerrank",
        "overleaf", "arxiv", "researchgate", "sciencedirect", "springer",
        "ieee", "acm.org", "wolframalpha", "mathworks", "mit.edu", "yale.edu",
        "baeldung", "jenkov", "stackoverflow", "stackexchange", "superuser",
        "serverfault", "spiceworks", "proandroiddev", "mybridge", "cljdoc",
        "flutterlearn", "fluttercrashcourse", "medium.com", "wikia",
        "goanimate", "grabcad"])]),
    ("hardware", "سخت‌افزار و درایور", [("main", "همه", [
        "intel", "amd.com", "qualcomm", "xilinx", "altera", "microchip",
        "st.com", "espressif", "raspberrypi", "arduino", "digikey",
        "element14", "ti.com", "ni.com", "dell.com", "lenovo", "cisco",
        "samsung", "android", "sun.com", "download.01.org", "clamav",
        "anydesk", "teamviewer", "bitvise", "nirsoft", "softonic"])]),
    ("finance", "پرداخت و مالی", [("main", "همه", [
        "paypal", "stripe", "coinbase", "payments.google", "mailgun",
        "sendgrid", "salesforce", "upwork", "demandbase", "en25.com"])]),
    ("webdev", "ابزار وب و فریم‌ورک", [("main", "همه", [
        "nodejs", "deno", "bun.sh", "python.org", "php.net", "ruby-doc",
        "rust-lang", "swift.org", "dartlang", "flutter", "reactjs", "vuejs",
        "vuetifyjs", "nextjs", "laravel", "symfony", "spring.io", "expressjs",
        "socket.io", "graphql", "apache", "nginx.com", "caddy", "mysql",
        "mongodb", "enterprisedb", "elastic.co", "grafana", "splunk",
        "cloudera", "datastax", "jaspersoft", "telerik", "nativescript",
        "polymer", "i18next", "eslint", "seleniumhq", "serialport",
        "sparkjava", "jhipster", "realm.io", "bootstrapcdn", "bootswatch",
        "getbootstrap", "ant.design", "material.io", "qt.io", "vagrantup",
        "hashicorp", "terraform", "jenkins", "travisci", "codecov",
        "metasploit", "rapid7", "postman", "sonarsource", "swaggerhub",
        "godbolt", "explainshell", "hyper.is", "curd.io", "bit.dev",
        "bitsrc", "b4x.com", "javacardos", "mbed", "gallery.io", "arcgis",
        "algolia", "atlassian", "cpanel", "schema.org", "amp.dev", "web.dev",
        "developer.chrome", "jungle.net", "beans.org", "sstatic",
        "i.stack.imgur"])]),
    ("assets", "تصویر، فونت و قالب", [("main", "همه", [
        "unsplash", "gravatar", "myfonts", "tinyjpg", "tinypng", "themeforest",
        "codecanyon", "graphicriver", "photodune", "videohive", "3docean",
        "envato", "wpastra", "toggl", "justpaste", "jwplayer", "maxcdn",
        "vmcdn", "slack-edge"])]),
    ("analytics", "تحلیل و تبلیغات", [("main", "همه", [
        "analytics", "tagmanager", "googletag", "adservice", "optimizely",
        "optimize.", "newrelic", "sentry", "bugsnag", "flurry", "parsely",
        "lightstep", "branch.io", "count.ly", "livefyre", "fabric.io",
        "traviscistatus", "fbsbx", "expo.io", "crashlytics", "fodev"])]),
]


def find(domain):
    for skey, _, groups in BRANDS:
        for gkey, _, patterns in groups:
            for p in patterns:
                if p in domain:
                    return skey, gkey
    return None, None


def main():
    path = os.path.join(ROOT, "domains", "domains.txt")
    domains = [l.strip() for l in io.open(path, encoding="utf-8")
               if l.strip() and not l.startswith("#")]

    buckets = {}
    unmatched = []
    for d in domains:
        skey, gkey = find(d)
        if skey is None:
            unmatched.append(d)
        else:
            buckets.setdefault((skey, gkey), []).append(d)
    for key, names in EXPLICIT.items():
        skey, gkey = key.split(".")
        buckets.setdefault((skey, gkey), []).extend(names)

    services = []
    for skey, slabel, groups in BRANDS:
        out_groups = []
        for gkey, glabel, _ in groups:
            names = sorted(set(buckets.get((skey, gkey), [])))
            if names:
                group = {"key": gkey, "label": glabel, "domains": names}
                # An opt-in group is listed but routed by nobody until an
                # operator ticks it - including by the default template, which
                # otherwise means "everything, now and later". Reserved for
                # groups where routing is the wrong default rather than a
                # matter of taste.
                if "%s.%s" % (skey, gkey) in OPT_IN:
                    group["opt_in"] = True
                out_groups.append(group)
        if out_groups:
            services.append({"key": skey, "label": slabel, "groups": out_groups})

    if unmatched:
        services.append({"key": "other", "label": "متفرقه", "groups": [
            {"key": "main", "label": "همه", "domains": sorted(unmatched)}]})

    dest = os.path.join(ROOT, "domains", "services.json")
    with io.open(dest, "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"services": services}, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    total = 0
    for s in services:
        n = sum(len(g["domains"]) for g in s["groups"])
        total += n
        detail = ""
        if len(s["groups"]) > 1:
            detail = "   [" + " | ".join(
                "%s %d" % (g["key"], len(g["domains"])) for g in s["groups"]) + "]"
        print("  %-14s %3d  %s%s" % (s["key"], n, s["label"], detail))
    expected = len(domains) + sum(len(v) for v in EXPLICIT.values())
    print("  %-14s %3d   (expected %d)" % ("TOTAL", total, expected))
    assert total == expected, "domains lost in classification"


if __name__ == "__main__":
    main()
