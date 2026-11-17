# 3x — Shopping: product cards, the product page, Notify Me and the order card

Owner, 2026-11-17, after a look at Grok Bot: "Let's pick some of those that we can build in. I like the shopping one."
Comparable, not a copy: Hermes HQ's own look (dense, glass sheets, soft cards), its own words, its own data shape.

## 1. What the person gets

1. **Product cards.** Asked to find or compare something to buy, the bot's reply carries product cards: photo, name,
   price (the old price struck through when there is one), store, rating, at most one short badge.
2. **Product page.** Tapping a card opens a sheet: photos, name, price, rating, options the bot chose (colour, size),
   "Why It Fits" (the bot's reasons, at most three, and cautions), "Where to Buy" (other stores' prices), details, and
   one main button: **Buy** (in stock) or **Notify Me** (out of stock). A quieter **Notify Me of a Price Drop** sits
   under Buy.
3. **Buy** sends the bot a message. The bot takes the item to the last step of checkout in its browser and then shows
   an **order card**.
4. **Order card.** Store, items, charges, total, ship to, pay with. Two buttons: **Cancel** and **Pay $123.45**.
   Nothing is paid without that tap. Afterwards the card says what happened.
5. **Notify Me** sends the bot a message that sets up a scheduled job (Hermes's own price watch).

One place per action: the card opens the page; the page holds Buy and Notify Me. No second way on the card itself,
except that a reply with exactly one product shows its Buy button on the card (it is the whole answer).

## 2. Wire: two add-on tools, as `draft_message` is (docs: the draft card)

Products and orders are **tool calls of the Hermes HQ add-on** (`hermes-hq-push`), not text in the reply. The app
draws the tool call's arguments; it never reads the tool's result. Nothing has to be hidden from the bubble, Copy,
Read Aloud or alerts. The add-on validates strictly and answers the model in words when the data is wrong.

Both tools are offered only once an app has said it draws these cards (the draft cards' handshake:
`PUT /api/plugins/hermes-hq-push/shopping/cards`, status flags `shoppingCards`, `shoppingCardsShown`), and only in
`hermes serve` turns.

### 2.1 `show_products`

```
{
  "note": "One short line above the cards (which one to pick and why). Optional, ≤ 200.",
  "products": [                      // 1…12
    {
      "title": "…",                  // required, ≤ 160
      "store": "…",                  // required, ≤ 60: who sells it at this price
      "url": "https://…",            // required: this product's own page at that store
      "price": 129.99,               // required unless stock is "out" with no known price
      "currency": "USD",             // ISO 4217, default USD
      "was": 159.99,                 // optional list price, must be above price
      "image": "https://…",          // optional main photo
      "images": ["https://…"],       // optional further photos, ≤ 8
      "brand": "…",                  // optional, ≤ 60
      "rating": 4.6,                 // optional, 0…5
      "reviews": 1234,               // optional count
      "badge": "Best value",         // optional, ≤ 24, at most one
      "stock": "in",                 // in | out | preorder | backorder (default in)
      "delivery": "Free shipping, arrives Fri",   // optional, ≤ 80
      "why": ["…"],                  // optional, ≤ 3, each ≤ 120: why it fits what was asked
      "caution": ["…"],              // optional, ≤ 2, each ≤ 120
      "options": [{"name": "Colour", "value": "Navy"}],   // optional, ≤ 4: what this price is for
      "specs": [{"label": "Weight", "value": "1.2 kg"}],   // optional, ≤ 8
      "offers": [                    // optional, ≤ 5: the same product at other stores
        {"store": "…", "url": "https://…", "price": 134.0, "was": 0, "stock": "in", "delivery": "…"}
      ]
    }
  ],
  "follow_ups": ["Show cheaper ones"]   // optional, ≤ 3, each ≤ 60: sent as your message when tapped
}
```

Answer at once: `{"products": "shown", "id": "p-xxxxxxxx", "note": SHOWN_NOTE}`. `SHOWN_NOTE` tells the bot the
person now sees the cards, not to repeat their details, to end with one short line, and what a Buy / Notify Me message
will look like.

Rules the add-on enforces (each refusal says what to fix): https URLs only; `was` > `price`; one currency per
product; counts and lengths above; prices are numbers, never strings with symbols; no invented ratings (the
description says: leave out what the store's page does not show).

A product's id: `"p-" +` first 8 hex of SHA-256 over `title\nstore\nurl` (each trimmed). Both sides compute it.

### 2.2 `order_card`

```
{
  "store": "…",                      // required, ≤ 60
  "site": "https://…",               // optional: the checkout's site
  "items": [                         // 1…20
    {"title": "…", "detail": "Navy, M", "qty": 1, "price": 129.99, "image": "https://…"}
  ],
  "charges": [                       // optional, ≤ 6: shipping, tax, fees; a discount is negative
    {"label": "Shipping", "amount": 0}, {"label": "Tax", "amount": 10.4}
  ],
  "total": 140.39,                   // required: exactly what the checkout page says will be charged
  "currency": "USD",
  "ship_to": {"name": "…", "address": "…"},    // optional
  "pay_with": "Visa ending 4242",    // optional, ≤ 60: as the checkout page names it; never a full number
  "arrives": "Fri, Nov 20",          // optional, ≤ 60
  "note": "…"                        // optional, ≤ 160 (a code that was applied, a return window)
}
```

Answer at once: `{"order": "waiting", "id": "o-xxxxxxxx", "note": WAITING_NOTE}`. The bot ends its reply with one
short line and stops. It must not press the store's final button until the answer arrives.

Order id: `"o-" +` first 8 hex of SHA-256 over `store\ntotal\ncurrency\n` + each item's `qty x title` joined by `\n`
(total with two decimals, e.g. `140.39`). Both sides compute it.

The description must say: call it only at the last step of checkout, with the real total from the page; a changed
total needs a new card; never call it for something the person did not ask to buy.

### 2.3 What the app sends back (ordinary user messages, as a draft card's answer is)

| Tap | Message text (what the bot reads) | Your bubble shows |
|---|---|---|
| Buy | `[Hermes HQ shopping p-…: buy]` ↵ `Buy this for me: <title>[ (<options>)] from <store> for <price>.` ↵ `<url>` ↵ `Check the price and that it is in stock, take it to the last step of checkout, then show me the order with order_card and wait for my answer before you pay.` | Buy: `<title>` |
| Notify Me (out of stock) | `[Hermes HQ shopping p-…: watch stock]` ↵ `Tell me when this is back in stock: <title>[ (<options>)] at <store>.` ↵ `<url>` ↵ `Set up a scheduled job that checks every 6 hours (use your price watch job if you have one) and tells me only when it is available.` | Notify me: `<title>` |
| Notify Me of a Price Drop | `[Hermes HQ shopping p-…: watch price]` ↵ `Tell me when the price of this drops below <price>: <title> at <store>.` ↵ `<url>` ↵ same job sentence, "only when it drops". | Notify me of a price drop: `<title>` |
| Pay | `[Hermes HQ order o-…: pay]` ↵ `Place this order now: <store>, total <total>. Pay exactly this total. If the total on the page is different now, stop and show me a new order card.` | Pay `<total>` |
| Cancel | `[Hermes HQ order o-…: cancel]` ↵ `Don't place this order. Nothing should be charged.` | Cancel order |
| a follow-up | its text | its text |

The card's state is read back from the transcript (as `DraftCards.answers` does), so it is the same after a relaunch
and on another device: an order card is **waiting** until a later user message opens with its `[Hermes HQ order
<id>: pay|cancel]`, then **approved** ("You approved $140.39") or **cancelled** ("Cancelled. Nothing was charged.").
An older waiting order card with a newer `order_card` call after it in the chat is **replaced** ("A newer order
replaced this one"), with no buttons. A product's Buy / Notify Me that was sent shows as a quiet "Asked to buy" /
"Watching" line on its page, read back the same way.

## 3. App

- `HermesKit/Shopping/ShoppingCards.swift`: the tools' names, the parsed models (`ShoppingCards.Products`,
  `.Product`, `.Offer`, `.Order`…), `products(_ call:)`, `order(_ call:)`, ids, the messages of §2.3, the answers
  read back from the transcript, `bubbleWords`. Pure, tested in `Tests/Shopping/`.
- Whole arguments are kept for both tools wherever `DraftCards.wholeArgsText` is (tool start, tool complete, stored
  history, the transcript cache's clip).
- Rows: `ChatRow.Kind.prompt(PromptRow)` gains `PromptRow.Kind.products(ProductsCardRow)` and `.order(OrderCardRow)`,
  built in the assistant builder's `.tool` case before the silent-tool check (as the draft row is).
- Product cards layout by count: 1 = one wide card with its Buy button; 2 = two side by side; 3…8 = a row that
  scrolls sideways; 9…12 = a list of compact rows (first 5, then one short "7 more ›" line under them, the grouped lines' wording; "Show Less" once open). Dense: name one line, price line,
  store line. Photos load through the existing remote image path (public https only). A missing photo is a quiet
  placeholder glyph.
- The product page is a glass sheet (`hqGlassSheetPage`), sized to its content up to large; on the Mac and iPad a
  form sheet.
- The order card is a soft card in the chat with its two buttons inside it, as the draft card has its three.
- Handshake: once the add-on's status has `shoppingCards` true and `shoppingCardsShown` not true, the app sends the
  PUT of §2 (beside the drafts' one in `PushRegistrar`). `PushPolicy` gains `shoppingCardsKnown` but does **not**
  require it yet (no update prompt until the add-on is published).
- Demo: `-HQDemoShopping` (a chat with 1, 2, 5 and 12 products and an order card), `-HQDemoShoppingOpen <n>` opens
  the nth product's page, `-HQDemoOrderState waiting|approved|cancelled|replaced`.

## 4. Not in the first version

Stored card numbers in the app, a cart, try-on, similar products fetched by the app, a special drawing of the
gateway's own "Confirm payment card fill?" approval, a one-tap job without a bot turn. A scheduled job cannot pay or
ask (Hermes turns questions off in scheduled runs): a watch only tells you.
