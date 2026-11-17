#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import UIKit

/// The views of the built-in screens. System colors and fonts only: light and dark follow the system, text follows
/// Dynamic Type, nothing is an image asset.
internal enum ControlViews {
    @_optimize(size) static func title(_ text: String) -> UILabel {
        let label = UILabel()
        let base = UIFont.preferredFont(forTextStyle: .title1)
        label.font = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0)
        label.text = text
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityTraits = .header
        return label
    }
    @_optimize(size) static func body(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.text = text
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }
    @_optimize(size) static func button(_ text: String, prominent: Bool, action: @escaping () -> Void) -> UIButton {
        var config = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.title = text
        config.buttonSize = .large
        config.cornerStyle = .large
        config.titleLineBreakMode = .byWordWrapping
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .headline)
            return outgoing
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.accessibilityLabel = text
        return button
    }
    @_optimize(size) static func stack(_ views: [UIView], spacing: CGFloat = 16) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A strip for the test build notice or an upcoming maintenance: dark text on yellow, readable in both themes.
    @_optimize(size) static func banner(_ text: String, dismissLabel: String?, onDismiss: @escaping () -> Void) -> UIView {
        let strip = UIView()
        strip.backgroundColor = .systemYellow
        strip.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.text = text
        label.textColor = .black
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityTraits = .staticText
        strip.addSubview(label)
        var trailing = strip.trailingAnchor
        var padding: CGFloat = 16
        if let dismissLabel = dismissLabel {
            let close = UIButton(type: .system, primaryAction: UIAction { _ in onDismiss() })
            close.setImage(UIImage(systemName: "xmark"), for: .normal)
            close.tintColor = .black
            close.accessibilityLabel = dismissLabel
            close.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -4),
                close.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
                close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44)])
            trailing = close.leadingAnchor; padding = 0
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: strip.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailing, constant: -padding),
            strip.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        return strip
    }

    // MARK: Layout helpers (one place instead of the same anchor code in every screen: smaller binary)

    /// A view with a background color, added to `parent` for Auto Layout.
    @_optimize(size) static func plain(_ color: UIColor, in parent: UIView) -> UIView {
        let view = add(UIView(), to: parent)
        view.backgroundColor = color
        return view
    }
    /// Adds `view` to `parent` for Auto Layout and returns it.
    @discardableResult @_optimize(size) static func add<V: UIView>(_ view: V, to parent: UIView) -> V {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        return view
    }
    /// Top, bottom, leading and trailing of `view` equal to those of `other`, `inset` points inside.
    @_optimize(size) static func edges(_ view: UIView, _ other: UIView, _ inset: CGFloat = 0) -> [NSLayoutConstraint] {
        [view.topAnchor.constraint(equalTo: other.topAnchor, constant: inset),
         view.bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -inset)] + sides(view, other, inset)
    }
    /// Leading and trailing of `view` equal to those of `other`, `inset` points inside.
    @_optimize(size) static func sides(_ view: UIView, _ other: UIView, _ inset: CGFloat = 0) -> [NSLayoutConstraint] {
        [view.leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: inset),
         view.trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -inset)]
    }
    /// Top, bottom, leading and trailing of `view` equal to those of `guide`.
    @_optimize(size) static func edges(_ view: UIView, guide: UILayoutGuide) -> [NSLayoutConstraint] {
        [view.topAnchor.constraint(equalTo: guide.topAnchor), view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
         view.leadingAnchor.constraint(equalTo: guide.leadingAnchor), view.trailingAnchor.constraint(equalTo: guide.trailingAnchor)]
    }

    /// Title, body and buttons of one screen, as a scrolling column that is centered when it is short and scrolls when
    /// the text is long (large Dynamic Type, long languages).
    @_optimize(size) static func scrollingColumn(content: UIStackView, in parent: UIView, maxWidth: CGFloat, guide: UILayoutGuide,
                                insets: UIEdgeInsets) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        scroll.contentInsetAdjustmentBehavior = .never
        add(scroll, to: parent)
        let holder = add(UIView(), to: scroll)
        holder.addSubview(content)
        let width = content.widthAnchor.constraint(equalToConstant: maxWidth)
        width.priority = .defaultHigh
        let outer = edges(scroll, guide: guide)
        outer[0].constant = insets.top
        outer[1].constant = -insets.bottom
        NSLayoutConstraint.activate(outer + edges(holder, guide: scroll.contentLayoutGuide) + [
            holder.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            holder.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            content.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: holder.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -24),
            width])
        return scroll
    }
}
#endif
