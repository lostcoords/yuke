use std::ffi::OsStr;
use std::io::Read as _;
use std::sync::{Mutex, mpsc};
use std::thread;
use std::time::Duration;

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::pty::{OpenptFlags, grantpt, openpt, ptsname, unlockpt};
use rustix::termios::{LocalModes, Winsize, tcsetwinsize};

use super::*;
use crate::event::{Code, Key, Modifiers};

/// A spawn waits while a test opens a controller, so a child process gets no controller of another test. It would keep
/// the controller open after the close of the test.
static SPAWN: Mutex<()> = Mutex::new(());

/// A pseudo-terminal: the controller side, and the device that a program reads as its terminal.
fn pty() -> (File, File) {
    let spawn = SPAWN.lock().unwrap();
    let controller = openpt(OpenptFlags::RDWR | OpenptFlags::NOCTTY).unwrap();
    rustix::io::fcntl_setfd(&controller, rustix::io::FdFlags::CLOEXEC).unwrap();
    drop(spawn);
    grantpt(&controller).unwrap();
    unlockpt(&controller).unwrap();
    let name = ptsname(&controller, Vec::new()).unwrap();
    let device = OpenOptions::new()
        .read(true)
        .write(true)
        .open(OsStr::from_bytes(name.as_bytes()))
        .unwrap();
    (File::from(controller), device)
}

/// Read from the controller until the output holds `end`. A missing `end` fails the test after a second.
fn read_until(controller: &mut File, end: &[u8]) -> Vec<u8> {
    let mut output = Vec::new();
    let mut buffer = [0; 1024];
    while !output.windows(end.len()).any(|window| window == end) {
        let mut fds = [PollFd::new(&*controller, PollFlags::IN)];
        let second = Timespec { tv_sec: 1, tv_nsec: 0 };
        assert_eq!(
            poll(&mut fds, Some(&second)).unwrap(),
            1,
            "no {end:?} in {:?}",
            String::from_utf8_lossy(&output)
        );
        let read = controller.read(&mut buffer).unwrap();
        assert_ne!(read, 0, "the device closed before {end:?}");
        output.extend_from_slice(&buffer[..read]);
    }
    output
}

fn canonical(device: &File) -> bool {
    termios::tcgetattr(device)
        .unwrap()
        .local_modes
        .contains(LocalModes::ICANON | LocalModes::ECHO)
}

/// Open a terminal on `device`, and answer its probe with `answers` from the controller.
fn open(controller: &mut File, device: File, answers: &[u8]) -> Terminal {
    let opening = thread::spawn(move || Terminal::from_file(device).unwrap());
    read_until(controller, b"\x1b[c");
    controller.write_all(answers).unwrap();
    opening.join().unwrap()
}

const DEVICE_ATTRIBUTES: &[u8] = b"\x1b[?62c";

#[test]
fn raw_mode_and_the_screen_modes_last_until_the_drop() {
    let (mut controller, device) = pty();
    let probe = device.try_clone().unwrap();
    assert!(canonical(&probe));

    let opening = thread::spawn(move || Terminal::from_file(device).unwrap());
    let output = read_until(&mut controller, b"\x1b[c");
    let expected = b"\x1b[?1049h\x1b[?2004h\x1b[?1002;1004;1006h\x1b[?2031h\x1b[>5u\x1b]11;?\x1b\\\x1b[?u\x1b[c";
    assert_eq!(output, expected);
    controller.write_all(b"\x1b[?5u\x1b[?62c").unwrap();
    let terminal = opening.join().unwrap();
    assert!(!canonical(&probe));

    drop(terminal);
    assert!(canonical(&probe));
    // Kitty keys need no modifyOtherKeys, so the drop does not reset it.
    assert_eq!(
        read_until(&mut controller, b"\x1b[?1049l"),
        b"\x1b[<u\x1b[?2031l\x1b[?1002;1004;1006l\x1b[?2004l\x1b[0m\x1b[0 q\x1b[?25h\x1b[?1049l"
    );
}

#[test]
fn the_probe_turns_on_the_modes_that_the_answers_allow_and_the_drop_turns_them_off() {
    let (mut controller, device) = pty();
    // A second handle keeps the device open after the drop, so its output stays readable.
    let _open = device.try_clone().unwrap();
    // A late kitty answer after the last answer changes nothing.
    let answers = b"\x1b]11;rgb:1e1e/1e1e/2e2e\x07\x1b[?0u\x1b[?62c\x1b[?5u";
    let terminal = open(&mut controller, device, answers);
    assert_eq!(
        terminal.background(),
        Some(Rgb {
            red: 0x1e,
            green: 0x1e,
            blue: 0x2e
        })
    );
    terminal.write_all(b"|").unwrap();
    // Kitty flags 0 mean no kitty keys, so modifyOtherKeys comes on.
    assert_eq!(read_until(&mut controller, b"|"), b"\x1b[>4;2m|");

    drop(terminal);
    let output = read_until(&mut controller, b"\x1b[?1049l");
    assert!(output.starts_with(b"\x1b[<u\x1b[>4m\x1b[?2031l"));
}

#[test]
fn a_silent_terminal_gives_no_background_and_modify_other_keys() {
    let (mut controller, device) = pty();
    let terminal = open(&mut controller, device, b"");
    assert_eq!(terminal.background(), None);
    terminal.write_all(b"|").unwrap();
    assert_eq!(read_until(&mut controller, b"|"), b"\x1b[>4;2m|");
}

#[test]
fn input_during_the_probe_reaches_the_first_reader() {
    let (mut controller, device) = pty();
    // A key, the last answer, and the start of an arrow key that the next read completes.
    let mut terminal = open(&mut controller, device, b"h\x1b[?62c\x1b[");
    let (send, events) = mpsc::channel();
    terminal
        .start_reader(move |event| send.send(event).unwrap(), || {})
        .unwrap();
    controller.write_all(b"A").unwrap();

    let second = Duration::from_secs(1);
    let mut h = Key::new(Code::Char('h'));
    h.text = "h".to_owned();
    assert_eq!(events.recv_timeout(second).unwrap(), Event::Key(h));
    assert_eq!(events.recv_timeout(second).unwrap(), Event::Key(Key::new(Code::Up)));
    terminal.stop_reader().unwrap();
}

#[test]
fn the_writer_writes_to_the_device() {
    let (mut controller, device) = pty();
    let terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    let mut writer = terminal.writer().unwrap();
    writer.write_all(b"|frame|").unwrap();
    assert!(read_until(&mut controller, b"|frame|").ends_with(b"|frame|"));
}

#[test]
fn the_size_is_the_size_of_the_device() {
    let (mut controller, device) = pty();
    tcsetwinsize(
        &controller,
        Winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        },
    )
    .unwrap();
    let terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    assert_eq!(terminal.size().unwrap(), Size { columns: 80, rows: 24 });
}

#[test]
fn the_reader_passes_events_until_the_stop() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    let (send, events) = mpsc::channel();
    terminal
        .start_reader(move |event| send.send(event).unwrap(), || {})
        .unwrap();

    // A key, a later background answer, a late probe answer that no one reads, and a key.
    controller
        .write_all(b"\x1b[A\x1b]11;rgb:ffff/ffff/ffff\x07\x1b[?62cx")
        .unwrap();
    let second = Duration::from_secs(1);
    assert_eq!(events.recv_timeout(second).unwrap(), Event::Key(Key::new(Code::Up)));
    let white = Rgb {
        red: 255,
        green: 255,
        blue: 255,
    };
    assert_eq!(events.recv_timeout(second).unwrap(), Event::Background(white));
    let mut x = Key::new(Code::Char('x'));
    x.text = "x".to_owned();
    assert_eq!(events.recv_timeout(second).unwrap(), Event::Key(x));

    terminal.stop_reader().unwrap();
    // The stopped thread dropped its callback, so the channel ends.
    assert_eq!(events.recv_timeout(second), Err(mpsc::RecvTimeoutError::Disconnected));
}

#[test]
fn a_second_reader_fails_until_the_first_stops() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    terminal.start_reader(|_| {}, || {}).unwrap();
    let error = terminal.start_reader(|_| {}, || {}).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);

    terminal.stop_reader().unwrap();
    let (send, events) = mpsc::channel();
    terminal
        .start_reader(move |event| send.send(event).unwrap(), || {})
        .unwrap();
    controller.write_all(b"\x1b[A").unwrap();
    assert_eq!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        Event::Key(Key::new(Code::Up))
    );
}

#[test]
fn the_drop_stops_the_reader() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    let (send, events) = mpsc::channel();
    terminal
        .start_reader(move |event| send.send(event).unwrap(), || {})
        .unwrap();
    drop(terminal);
    // The stopped thread dropped its callback, so the channel ends.
    assert_eq!(
        events.recv_timeout(Duration::from_secs(1)),
        Err(mpsc::RecvTimeoutError::Disconnected)
    );
}

#[test]
fn the_drop_stops_the_reader_before_it_restores_the_device() {
    let (mut controller, device) = pty();
    let probe = device.try_clone().unwrap();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    let (entered, entry) = mpsc::channel();
    let (send, modes) = mpsc::channel();
    terminal
        .start_reader(
            move |_| {
                entered.send(()).unwrap();
                // The drop runs now. It must wait for this call before it restores the device.
                thread::sleep(Duration::from_millis(100));
                send.send(canonical(&probe)).unwrap();
            },
            || {},
        )
        .unwrap();
    controller.write_all(b"a").unwrap();
    entry.recv_timeout(Duration::from_secs(1)).unwrap();
    drop(terminal);
    assert_eq!(modes.recv_timeout(Duration::from_secs(1)), Ok(false));
}

#[test]
fn a_stop_does_not_call_ended_and_the_end_of_the_input_does() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    let (send, ends) = mpsc::channel();
    let stop_end = send.clone();
    terminal
        .start_reader(|_| {}, move || stop_end.send(()).unwrap())
        .unwrap();
    terminal.stop_reader().unwrap();
    assert_eq!(ends.try_recv(), Err(mpsc::TryRecvError::Empty));

    terminal.start_reader(|_| {}, move || send.send(()).unwrap()).unwrap();
    // The close of the controller ends the input of the device.
    drop(controller);
    // A busy macOS gives the hang-up after more than a second.
    assert_eq!(ends.recv_timeout(Duration::from_secs(5)), Ok(()));
}

#[test]
fn a_child_process_does_not_keep_the_reader_from_its_stop() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    terminal.start_reader(|_| {}, || {}).unwrap();
    let spawn = SPAWN.lock().unwrap();
    let mut child = std::process::Command::new("sleep").arg("5").spawn().unwrap();
    drop(spawn);
    let started = Instant::now();
    terminal.stop_reader().unwrap();
    let waited = started.elapsed();
    child.kill().unwrap();
    child.wait().unwrap();
    // A child that holds the write end of the stop pipe makes the stop wait for the child.
    assert!(waited < Duration::from_secs(2), "the stop waited {waited:?}");
}

#[test]
fn a_lone_escape_byte_becomes_the_escape_key_after_the_assembly_timeout() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    let (send, events) = mpsc::channel();
    terminal
        .start_reader(move |event| send.send(event).unwrap(), || {})
        .unwrap();
    controller.write_all(b"\x1b").unwrap();
    assert_eq!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        Event::Key(Key::new(Code::Escape))
    );
}

#[test]
fn more_bytes_of_a_cut_sequence_do_not_hold_back_its_flush() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, DEVICE_ATTRIBUTES);
    let (send, events) = mpsc::channel();
    terminal
        .start_reader(move |event| send.send((event, Instant::now())).unwrap(), || {})
        .unwrap();
    // A CSI that never ends: a byte each 20 ms for 400 ms. A busy wait, because a macOS sleep overshoots.
    controller.write_all(b"\x1b[").unwrap();
    let started = Instant::now();
    let mut last = started;
    while started.elapsed() < Duration::from_millis(400) {
        if last.elapsed() >= Duration::from_millis(20) {
            controller.write_all(b"1").unwrap();
            last = Instant::now();
        }
    }
    let (first, at) = events.recv_timeout(Duration::from_secs(1)).unwrap();
    let mut alt = Key::new(Code::Char('['));
    alt.modifiers = Modifiers::ALT;
    assert_eq!(first, Event::Key(alt));
    assert!(at < last, "the flush came {:?} after the last byte", at - last);
}

#[test]
fn a_lone_escape_byte_of_the_probe_input_reaches_the_first_reader() {
    let (mut controller, device) = pty();
    let mut terminal = open(&mut controller, device, b"\x1b[?62c\x1b");
    let (send, events) = mpsc::channel();
    terminal
        .start_reader(move |event| send.send(event).unwrap(), || {})
        .unwrap();
    assert_eq!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        Event::Key(Key::new(Code::Escape))
    );
}
