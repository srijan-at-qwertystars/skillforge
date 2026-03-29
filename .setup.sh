rm -rf ~/skillforge-refine
cd ~/skillforge && git pull
mkdir -p ~/skillforge/reviews
gh label create qa --repo srijan-at-qwertystars/skillforge --description "Automated QA findings" --color "d93f0b" 2>/dev/null || true
