#!/usr/bin/env python3
"""Read-only Obsi Markdown quality audit. No network, writes or image access."""
import argparse
import collections
import hashlib
import json
import re
from pathlib import Path

TOP = ('Homelab', 'Work', 'Infrastructure')
FIELDS = ('status', 'last-updated', 'last-verified')
WIKI = re.compile(r'(?<!!)\[\[([^\]\n]+)\]\]|!\[\[([^\]\n]+)\]\]')
IP_HOME = re.compile(r'(?<!\d)10\.69\.(?:\d{1,3}\.)\d{1,3}(?!\d)')
IP_WORK = re.compile(r'(?<!\d)10\.101\.(?:\d{1,3}\.)\d{1,3}(?!\d)')


def metadata(text):
    values = {}
    if text.startswith('---\n'):
        match = re.search(r'(?m)^---\s*$', text[4:])
        if match:
            for line in text[4:4+match.start()].splitlines():
                if ':' in line:
                    key, value = line.split(':', 1)
                    if key.strip() in FIELDS:
                        values[key.strip()] = value.strip().strip('"\'')
    return values


def redirect_target(text):
    # A redirect is a short note explicitly declaring its destination.
    body = re.sub(r'^---\\n.*?\\n---\\n', '', text, count=1, flags=re.S).strip()
    found = re.search(r'This note has moved to\\s+\\*\\*\\[\\[([^]\\n]+)\\]\\]\\*\\*', body, flags=re.I)
    if found and len(body) < 500 and ('# ' in body or 'moved' in body.lower()):
        return found.group(1).split('|', 1)[0].strip()
    return None


def analyze(root):
    root = root.resolve()
    if not root.is_dir() or not (root / '.obsi-storage-check').is_file():
        raise ValueError('Not an Obsi vault with safety marker')
    notes, warnings = [], []
    for folder in TOP:
        base = root / folder
        if not base.exists() or base.is_symlink():
            continue
        for path in sorted(base.rglob('*.md')):
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
                continue
            if path.stat().st_size > 256*1024:
                warnings.append({'kind':'oversized_note_skipped','path':path.relative_to(root).as_posix()})
                continue
            try:
                raw = path.read_bytes()
                text = raw.decode('utf-8')
            except (UnicodeError, OSError):
                warnings.append({'kind':'unreadable_note_skipped','path':path.relative_to(root).as_posix()})
                continue
            refs = []
            for m in WIKI.finditer(text):
                ref = (m.group(1) or m.group(2)).split('|')[0].split('#')[0].strip()
                if ref:
                    refs.append(ref)
            notes.append({'path':path.relative_to(root).as_posix(), 'title':path.stem,
                          'hash':hashlib.sha256(raw).hexdigest(), 'metadata':metadata(text),
                          'links':refs, 'redirect_to':redirect_target(text), 'ip_home':bool(IP_HOME.search(text)),
                          'ip_work':bool(IP_WORK.search(text))})
    groups_title=collections.defaultdict(list); groups_hash=collections.defaultdict(list)
    stem_map=collections.defaultdict(list)
    all_paths={n['path'] for n in notes}
    for n in notes:
        groups_title[re.sub(r'[^a-z0-9]', '', n['title'].lower())].append(n['path'])
        groups_hash[n['hash']].append(n['path'])
        stem_map[n['title'].lower()].append(n['path'])
    issues = warnings[:]
    for paths in groups_hash.values():
        if len(paths)>1: issues.append({'kind':'identical_content', 'paths':paths})
    for paths in groups_title.values():
        if len(paths)>1 and not any(next(n for n in notes if n['path'] == p)['redirect_to'] for p in paths):
            issues.append({'kind':'same_title_candidate', 'paths':paths})
    incoming=collections.defaultdict(list)
    for source in notes:
        for link in source['links']:
            normalized=link.removesuffix('.md')
            for target in notes:
                target_norm=target['path'].removesuffix('.md')
                if normalized == target_norm or ('/' not in normalized and normalized.lower() == target['title'].lower()):
                    incoming[target['path']].append(source['path'])
    for n in notes:
        p=n['path']
        if n['redirect_to']:
            issues.append({'kind':'redirect_placeholder','path':p,'target':n['redirect_to'],
                           'incoming_links':sorted(set(incoming[p])),
                           'action':'review incoming links and Obsidian references before removal'})
        elif p.startswith('Infrastructure/'):
            issues.append({'kind':'legacy_folder','path':p})
        if not n['redirect_to'] and (p.startswith('Homelab/') and n['ip_work'] and not n['ip_home'] or p.startswith('Work/') and n['ip_home'] and not n['ip_work']):
            issues.append({'kind':'possible_environment_mismatch','path':p})
        missing=[f for f in FIELDS if not n['metadata'].get(f)] if not n['redirect_to'] else []
        if missing: issues.append({'kind':'missing_metadata','path':p,'fields':missing})
        for link in n['links']:
            if link.startswith('Attachments/'):
                attachment = root / link
                if not attachment.is_file(): issues.append({'kind':'missing_attachment','path':p,'link':link})
                continue
            target=link if link.endswith('.md') else link+'.md'
            if target in all_paths or ('/' not in link and Path(target).stem.lower() in stem_map):
                continue
            issues.append({'kind':'unresolved_wikilink','path':p,'link':link})
    return {'mode':'read_only', 'notes_checked':len(notes),'issue_count':len(issues),
            'issues':issues, 'notes':[{'path':n['path'],'metadata':n['metadata'],
                                     'outgoing_links':len(n['links']), 'redirect_to':n['redirect_to']} for n in notes],
            'limitations':['Same titles do not prove duplicate content.',
                           'Different facts or values cannot be reliably labeled conflicts without contextual review.',
                           'Missing last-verified is not evidence that a system is unverified.',
                           'Unqualified wiki-links are matched by note basename only.',
                           'Environment mismatch flags are conservative heuristics, not proof.',
                           'Redirect removal requires reviewing backlinks outside this vault too.']]}

if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--root', default='/srv/obsi-ai')
    args=ap.parse_args()
    print(json.dumps(analyze(Path(args.root)), ensure_ascii=False, indent=2))
