import SwiftUI

struct CheckoutScreen: View {
    @State private var cart: Cart?
    @State private var name = "Anna Petrova"
    @State private var address = ""
    @State private var express = true
    @State private var payment = "Apple Pay"

    var body: some View {
        Form {
            Section("Contact") {
                TextField("Full name", text: $name)
                TextField("Delivery address", text: $address)
            }
            Section("Options") {
                Toggle("Express delivery", isOn: $express)
                Picker("Payment", selection: $payment) {
                    ForEach(["Apple Pay", "Card", "PayPal"], id: \.self) { Text($0) }
                }
            }
            Section("Order") {
                if let cart {
                    ForEach(cart.items, id: \.self) { item in
                        LabeledContent(item.name, value: item.price)
                    }
                    LabeledContent("Delivery", value: cart.delivery)
                    OrderTotalRow(total: cart.total)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            PayButton(total: cart?.total ?? "—")
        }
        .navigationTitle("Checkout")
        .navigationBarTitleDisplayMode(.inline)
        .task { cart = await DemoAPI.shared.cart() }
    }
}

struct OrderTotalRow: View {
    let total: String

    var body: some View {
        HStack {
            Text("Total").font(.headline)
            Spacer()
            Text(total).font(.title3.weight(.bold)).monospacedDigit()
        }
    }
}

struct PayButton: View {
    let total: String

    var body: some View {
        Button {} label: {
            HStack {
                Image(systemName: "lock.fill")
                Text("Pay \(total)")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)   // off the 4pt grid on purpose – see Lint mode
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(.bar)
    }
}
