#if DEBUG
import Foundation

// [shopping] `-HQDemoShopping`: a chat that holds, in order, replies with 1, 2, 5 and 12 product cards (one product
// out of stock, one with a struck list price, one without a photo), then an order card. `-HQDemoOrderState
// approved|cancelled|replaced` adds your answer, or a newer order, after it (waiting by default). Made-up stores and
// example.com links only.

extension FakeChatSession {
    static var shoppingMessages: [ChatMessage] {
        func photo(_ word: String) -> JSONValue { .string("https://picsum.photos/seed/\(word)/600/600") }
        func product(_ title: String, _ store: String, _ price: Double, seed: String?, was: Double? = nil, rating: Double? = nil,
                     reviews: Int? = nil, badge: String? = nil, stock: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = [
                "title": .string(title), "store": .string(store), "price": .number(price), "currency": .string("USD"),
                "url": .string("https://example.com/p/" + title.lowercased().replacingOccurrences(of: " ", with: "-")),
            ]
            if let seed { o["image"] = photo(seed) }
            if let was { o["was"] = .number(was) }
            if let rating { o["rating"] = .number(rating) }
            if let reviews { o["reviews"] = .number(Double(reviews)) }
            if let badge { o["badge"] = .string(badge) }
            if let stock { o["stock"] = .string(stock) }
            o.merge(extra) { _, new in new }
            return .object(o)
        }
        func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> ChatPart {
            .tool(ToolCall(id: id, name: name, title: name == ShoppingCards.orderTool ? "Order card" : "Show products",
                           argsText: ChatJSON.stringify(.object(args)), summary: nil, state: .done, durationSeconds: 0.1))
        }
        let runner = product("Trail Runner 2", "Example Outfitters", 129.99, seed: "runner", was: 159.99, rating: 4.6, reviews: 1234,
                             badge: "Best value", extra: [
                                "brand": .string("Otto Sports"), "delivery": .string("Free shipping, arrives Fri"),
                                "images": .array([photo("runner2"), photo("runner3")]),
                                "why": .array([.string("Wide toe box, as you asked"), .string("Under your $150 limit"),
                                               .string("Grippy sole for wet trails")]),
                                "caution": .array([.string("Runs half a size small")]),
                                "options": .array([.object(["name": .string("Colour"), "value": .string("Navy")]),
                                                   .object(["name": .string("Size"), "value": .string("10")])]),
                                "specs": .array([.object(["label": .string("Weight"), "value": .string("280 g")]),
                                                 .object(["label": .string("Drop"), "value": .string("6 mm")])]),
                                "offers": .array([.object(["store": .string("Demo Goods"), "url": .string("https://example.com/demo-goods/trail-runner-2"),
                                                           "price": .number(134), "stock": .string("in"), "delivery": .string("Arrives Mon")]),
                                                  .object(["store": .string("Sample Supply"), "url": .string("https://example.com/sample/trail-runner-2"),
                                                           "price": .number(139.5)])]),
                             ])
        let pair: [JSONValue] = [
            product("Wool Socks", "Example Outfitters", 18, seed: "socks", rating: 4.8, reviews: 312),
            product("Trail Socks Lite", "Demo Goods", 14.5, seed: "socks2", was: 19, rating: 4.3, reviews: 88),
        ]
        let five: [JSONValue] = [
            product("Day Pack 20", "Example Outfitters", 89, seed: "pack", rating: 4.7, reviews: 540, badge: "Top pick"),
            product("Hydration Vest", "Demo Goods", 64.99, seed: "vest", was: 79.99, rating: 4.4, reviews: 201),
            product("Rain Shell", "Sample Supply", 149, seed: "shell", rating: 4.5, reviews: 97, stock: "out"),
            product("Head Lamp 400", "Example Outfitters", 39.95, seed: "lamp", rating: 4.6, reviews: 1890),
            product("Trekking Poles", "Demo Goods", 72, seed: nil, rating: 4.2, reviews: 45),
        ]
        let names = ["Camp Mug", "Fire Starter", "Map Case", "Sit Pad", "Bug Net", "Dry Bag", "Spork Set", "Water Filter",
                     "Bandana", "Sun Hat", "Gaiters", "Compass"]
        let twelve: [JSONValue] = names.enumerated().map { i, name in
            product(name, ["Example Outfitters", "Demo Goods", "Sample Supply"][i % 3], 9.5 + Double(i) * 4.25,
                    seed: i == 4 ? nil : "kit\(i)", was: i == 1 ? 24 : nil, rating: 4 + Double(i % 9) / 10, reviews: 20 + i * 37,
                    badge: i == 0 ? "Cheapest" : nil, stock: i == 2 ? "out" : nil)
        }
        let order: [String: JSONValue] = [
            "store": .string("Example Outfitters"), "site": .string("https://example.com/checkout"),
            "items": .array([.object(["title": .string("Trail Runner 2"), "detail": .string("Navy, 10"), "qty": .number(1), "price": .number(129.99)]),
                             .object(["title": .string("Wool Socks"), "detail": .string("Grey, M · in the bundle"), "qty": .number(2)])]),
            "charges": .array([.object(["label": .string("Shipping"), "amount": .number(0)]), .object(["label": .string("Tax"), "amount": .number(10.4)])]),
            "total": .number(140.39), "currency": .string("USD"),
            "ship_to": .object(["name": .string("Wren Example"), "address": .string("1 Demo Street, Springfield 01234")]),
            "pay_with": .string("Visa ending 4242"), "arrives": .string("Fri, Nov 20"), "note": .string("Free returns for 30 days."),
        ]
        let t = Date().addingTimeInterval(-900)
        var out: [ChatMessage] = [
            ChatMessage(id: "shop-u1", role: .user, parts: [.text("Find me a trail running shoe with a wide toe box under $150.")], timestamp: t, rowId: 9201),
            ChatMessage(id: "shop-a1", role: .assistant, parts: [
                call("shop-c1", ShoppingCards.productsTool, ["note": .string("This one fits all three things you asked for."), "products": .array([runner])]),
                .text("The Trail Runner 2 is the one I'd pick."),
            ], timestamp: t.addingTimeInterval(20), rowId: 9202),
            ChatMessage(id: "shop-u2", role: .user, parts: [.text("And socks to go with them?")], timestamp: t.addingTimeInterval(60), rowId: 9203),
            ChatMessage(id: "shop-a2", role: .assistant, parts: [call("shop-c2", ShoppingCards.productsTool, ["products": .array(pair)]),
                                                                 .text("Two good ones; the wool pair lasts longer.")],
                        timestamp: t.addingTimeInterval(80), rowId: 9204),
            ChatMessage(id: "shop-u3", role: .user, parts: [.text("What else do I need for a day hike?")], timestamp: t.addingTimeInterval(120), rowId: 9205),
            ChatMessage(id: "shop-a3", role: .assistant, parts: [
                call("shop-c3", ShoppingCards.productsTool, ["note": .string("The essentials, best first."), "products": .array(five),
                                                             "follow_ups": .array([.string("Show cheaper ones"), .string("Only in stock")])]),
                .text("The day pack matters most."),
            ], timestamp: t.addingTimeInterval(140), rowId: 9206),
            ChatMessage(id: "shop-u4", role: .user, parts: [.text("And small camp kit under $60?")], timestamp: t.addingTimeInterval(180), rowId: 9207),
            ChatMessage(id: "shop-a4", role: .assistant, parts: [call("shop-c4", ShoppingCards.productsTool, ["products": .array(twelve)]),
                                                                 .text("Twelve that fit.")],
                        timestamp: t.addingTimeInterval(200), rowId: 9208),
            ChatMessage(id: "shop-u5", role: .user, parts: [.text("Buy the shoes and two pairs of the wool socks.")], timestamp: t.addingTimeInterval(240), rowId: 9209),
            ChatMessage(id: "shop-a5", role: .assistant, parts: [call("shop-c5", ShoppingCards.orderTool, order),
                                                                 .text("It's at the last step. Pay when you're ready.")],
                        timestamp: t.addingTimeInterval(300), rowId: 9210),
        ]
        let state = ChatDemo.argument("-HQDemoOrderState") ?? "waiting"
        if state == "approved" || state == "cancelled", let made = ShoppingCards.order(order) {
            let text = state == "approved" ? ShoppingCards.payMessage(made) : ShoppingCards.cancelMessage(made)
            out.append(ChatMessage(id: "shop-u6", role: .user, parts: [.text(text)], timestamp: t.addingTimeInterval(330), rowId: 9211))
            out.append(ChatMessage(id: "shop-a6", role: .assistant, parts: [.text(state == "approved" ? "Placed. It arrives Friday." : "Okay, nothing was ordered.")],
                                   timestamp: t.addingTimeInterval(340), rowId: 9212))
        } else if state == "replaced" {
            var newer = order
            newer["total"] = .number(145.79)
            newer["charges"] = .array([.object(["label": .string("Shipping"), "amount": .number(5.4)]), .object(["label": .string("Tax"), "amount": .number(10.4)])])
            out.append(ChatMessage(id: "shop-u6", role: .user, parts: [.text("Make it two-day shipping.")], timestamp: t.addingTimeInterval(330), rowId: 9211))
            out.append(ChatMessage(id: "shop-a6", role: .assistant, parts: [call("shop-c6", ShoppingCards.orderTool, newer),
                                                                            .text("Two-day shipping adds $5.40.")],
                                   timestamp: t.addingTimeInterval(340), rowId: 9212))
        }
        return out
    }
}
#endif
