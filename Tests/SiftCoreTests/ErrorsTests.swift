import Foundation
import Testing
@testable import SiftCore

// Every SiftCore error must read as a sentence through BOTH string paths.
//
// `"\(error)"` goes to CustomStringConvertible; `error.localizedDescription` goes through
// Foundation's NSError bridge, which — without LocalizedError — synthesizes "The operation
// couldn't be completed. (SiftCore.SQLRejected error 1.)". `.localizedDescription` is the first
// thing a SwiftUI author reaches for, and Guard.swift's header says this module exists precisely
// so the user gets a sentence instead of a dump. This is the regression guard for that seam.

private let everyError: [(any SiftError, String)] = [
    (SQLRejected("Nothing to run."), "Nothing to run."),
    (UnsupportedSource("data is a folder with no .parquet or .csv files in it."),
     "data is a folder with no .parquet or .csv files in it."),
    (LegacyXls("old.xls is a legacy .xls file. Re-save it as .xlsx."),
     "old.xls is a legacy .xls file. Re-save it as .xlsx."),
    (TimeTravelUnsupported(), "time travel only applies to Delta tables"),
    (NoFreeTableName(filename: "sales.csv"), "cannot find a free table name for 'sales.csv'"),
    (UnknownColumn(column: "regoin"), "unknown column 'regoin'"),
    (UnsafeTypeName(type: "BIGINT); DROP TABLE x; --"),
     "refusing to interpolate suspicious type name 'BIGINT); DROP TABLE x; --'"),
    (UnknownDialect("excel"), "unknown dialect 'excel'"),
]

@Test func everyErrorGivesTheSameSentenceThroughBothStringPaths() {
    #expect(everyError.count == 8, "a new error type was added without a case here")
    for (error, sentence) in everyError {
        #expect("\(error)" == sentence)
        #expect(error.localizedDescription == sentence)
        // The bridged NSError path too, since that is what AppKit alerts and SwiftUI read.
        #expect((error as NSError).localizedDescription == sentence)
    }
}
