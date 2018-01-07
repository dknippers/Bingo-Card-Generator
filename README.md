# Bingo Card Generator
Super simple Bingo card generator which works with an input text file to specify the possible values to be put on the card. Will output a PDF containing 1 or more cards per page, which is configurable. Cards will automatically resize to fill up all available space on an A4.

## Usage
Make sure [Prawn](https://github.com/prawnpdf/prawn) is installed.

```
ruby bingo.rb <rows> <columns> <amount_of_cards> <cards_per_page> [header]
```

# Preview
Sample output PDF for 5x5 cards, 3 cards per page, with header "Simple Math Bingo Card :-)". Note the header takes up a row.

![Bingo Preview](img/preview.png?raw=true "Bingo Preview")