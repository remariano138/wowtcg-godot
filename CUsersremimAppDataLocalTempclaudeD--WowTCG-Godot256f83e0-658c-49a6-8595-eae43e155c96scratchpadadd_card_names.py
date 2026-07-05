import json
import csv
from pathlib import Path

# Build card ID to name mapping
card_map = {}
with open('data/cards.csv', 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        expansion = row['expansion'].strip()
        collector_number = row['collector_number'].strip()
        name = row['name'].strip()
        card_id = f"{expansion}_{collector_number}"
        card_map[card_id] = name

# Update all deck files
deck_files = Path('decks').glob('**/*.json')
for deck_file in sorted(deck_files):
    with open(deck_file, 'r', encoding='utf-8') as f:
        deck = json.load(f)
    
    # Add card names to entries
    for entry in deck.get('card_entries', []):
        card_id = entry['card_def_id']
        if card_id in card_map:
            entry['_card_name'] = card_map[card_id]
    
    # Also add the hero name
    hero_id = deck.get('hero_card_def_id')
    if hero_id and hero_id in card_map:
        deck['_hero_name'] = card_map[hero_id]
    
    # Write back with nice formatting
    with open(deck_file, 'w', encoding='utf-8') as f:
        json.dump(deck, f, indent=2)
    
    print(f"Updated {deck_file}")

print("Done!")
