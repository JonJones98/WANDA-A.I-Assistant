//
//  Calendar.swift
//  Wanda
//

import EventKit
import MapKit

/// Reads and adds events in the user's calendars (Calendar app, iCloud, Google…) and reads
/// reminders, through EventKit. macOS asks for Calendar and Reminders access the first time.
@MainActor
final class CalendarService {
    struct Item: Equatable {
        let title: String
        let start: Date
        let isAllDay: Bool
    }

    enum Failure: Error {
        case noAccess
    }

    private let store = EKEventStore()

    /// Asks for access if it hasn't been decided; true if Wanda may read and add events.
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// The events on `day`, earliest first.
    func events(on day: Date) async throws -> [Item] {
        guard await requestAccess() else { throw Failure.noAccess }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { Item(title: $0.title ?? "Untitled event", start: $0.startDate, isAllDay: $0.isAllDay) }
    }

    /// Adds an event to the default calendar, with an alert `alertBefore` seconds before it
    /// starts. An identical event (same title and start) is reused instead of duplicated.
    func addEvent(title: String, start: Date, end: Date, location: String, notes: String? = nil,
                  alertBefore: TimeInterval) async throws {
        guard await requestAccess() else { throw Failure.noAccess }
        let sameTime = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let event = store.events(matching: sameTime).first { $0.title == title && $0.startDate == start }
            ?? EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = event.calendar ?? store.defaultCalendarForNewEvents
        event.alarms = [EKAlarm(relativeOffset: -alertBefore)]
        try store.save(event, span: .thisEvent)
    }

    /// Asks for Reminders access if it hasn't been decided.
    func requestReminderAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .reminder) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// Titles of unfinished reminders due by the end of today (overdue ones included).
    func remindersDue() async throws -> [String] {
        guard await requestReminderAccess() else { throw Failure.noAccess }
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        return await reminderTitles(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil))
    }

    /// Titles of reminders completed yesterday.
    func remindersCompletedYesterday() async throws -> [String] {
        guard await requestReminderAccess() else { throw Failure.noAccess }
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        return await reminderTitles(store.predicateForCompletedReminders(withCompletionDateStarting: yesterday, ending: today, calendars: nil))
    }

    private func reminderTitles(_ predicate: NSPredicate) async -> [String] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(\.title))
            }
        }
    }

    static let permissionHint =
        "I need access to your calendar. Allow Wanda in System Settings → Privacy & Security → Calendars."

    /// "You have 2 things today: Standup at 9:00 AM and Dentist at 3:30 PM."
    nonisolated static func summary(_ items: [Item], day: String) -> String {
        guard !items.isEmpty else { return "Your calendar is clear \(day)." }
        let shown = items.prefix(5).map { item in
            item.isAllDay ? "\(item.title) (all day)" : "\(item.title) at \(item.start.formatted(date: .omitted, time: .shortened))"
        }
        let more = items.count > 5 ? ", and \(items.count - 5) more" : ""
        let count = items.count == 1 ? "one thing" : "\(items.count) things"
        return "You have \(count) \(day): \(ListFormatter.localizedString(byJoining: shown))\(more)."
    }

    /// Driving time from where the Mac is to `address`, or nil if Maps can't tell.
    static func drivingTime(to address: String) async -> TimeInterval? {
        await withTaskGroup(of: TimeInterval?.self) { group in
            group.addTask { @MainActor in
                guard let placemark = try? await CLGeocoder().geocodeAddressString(address).first else { return nil }
                let request = MKDirections.Request()
                request.source = .forCurrentLocation()
                request.destination = MKMapItem(placemark: MKPlacemark(placemark: placemark))
                request.transportType = .automobile
                return try? await MKDirections(request: request).calculateETA().expectedTravelTime
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
