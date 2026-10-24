import Testing
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T,_ b: @autoclosure () throws -> T) { do { let lhs=try a(),rhs=try b(); #expect(lhs==rhs) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertTrue(_ a: @autoclosure () throws -> Bool) { do { let value=try a(); #expect(value) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertFalse(_ a: @autoclosure () throws -> Bool) { do { let value=try a(); #expect(!value) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?) { do { let value=try a(); #expect(value==nil) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertNotNil<T>(_ a: @autoclosure () throws -> T?) { do { let value=try a(); #expect(value != nil) } catch { Issue.record("Unexpected error: \(error)") } }
func XCTAssertThrowsError<T>(_ a: @autoclosure () throws -> T) { do { _=try a(); Issue.record("Expected rejection") } catch {} }
func XCTAssertNoThrow<T>(_ a: @autoclosure () throws -> T) { do { _=try a() } catch { Issue.record("Unexpected rejection: \(error)") } }
