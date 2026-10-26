import re
import urllib.request

u = 'http://www.metamute.org/editorial/magazine/mute-vol-1-no.-0-can-art-survive-20th-century.html'
req = urllib.request.Request(u, headers={'User-Agent': 'Mozilla/5.0'})
html = urllib.request.urlopen(req, timeout=20).read().decode('utf-8', 'ignore')
links = re.findall(r'href=[\"\']([^\"\']+)[\"\']', html)
seen = []
for link in links:
    if link not in seen:
        seen.append(link)
print('links unique', len(seen))
for link in seen[:120]:
    print(link)
