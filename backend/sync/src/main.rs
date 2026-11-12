mod diffops;
mod sourcemap;
mod state;

use std::{
    env,
    io::ErrorKind,
    net::{TcpListener, TcpStream},
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use state::{Client, State, SyncRequest};
use tungstenite::{Error, Message};

fn serve(state: Arc<Mutex<State>>, stream: TcpStream) {
    let Ok(mut socket) = tungstenite::accept(stream) else {
        return;
    };
    let _ = socket.get_ref().set_read_timeout(Some(Duration::from_millis(50)));
    let id = state.lock().unwrap().begin_connection();
    println!("studio connected");

    let mut client = Client::default();
    loop {
        match socket.read() {
            Ok(Message::Text(text)) => {
                match serde_json::from_str::<SyncRequest>(text.as_str()) {
                    Ok(req) => {
                        let mut st = state.lock().unwrap();
                        if st.is_active(id) {
                            st.handle(req, &mut client);
                        }
                    }
                    Err(e) => println!("bad message ({} bytes): {e}", text.len()),
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(_) => break,
        }

        let outgoing = {
            let mut st = state.lock().unwrap();
            if !st.is_active(id) {
                break;
            }
            st.outgoing(&mut client)
        };
        if let Some(response) = outgoing {
            let json = serde_json::to_string(&response).unwrap();
            if socket.send(Message::text(json)).is_err() {
                break;
            }
        }
    }

    state.lock().unwrap().end_connection(id);
    println!("studio disconnected");
}

fn main() {
    let mut project = PathBuf::from(".");
    let mut sourcemap = None;
    let mut port = 34872u16;

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--project" => project = PathBuf::from(args.next().expect("--project needs a value")),
            "--sourcemap" => sourcemap = args.next().map(PathBuf::from),
            "--port" => port = args.next().and_then(|p| p.parse().ok()).expect("bad --port"),
            _ => panic!("unknown argument {arg}"),
        }
    }
    let sourcemap = sourcemap.unwrap_or_else(|| project.join("sourcemap.json"));

    let state = Arc::new(Mutex::new(State::new(project, sourcemap)));

    let poller = Arc::clone(&state);
    thread::spawn(move || loop {
        poller.lock().unwrap().poll();
        thread::sleep(Duration::from_millis(250));
    });

    let listener = TcpListener::bind(("127.0.0.1", port)).expect("failed to bind");
    println!("sync_backend listening on ws://127.0.0.1:{port}");

    for stream in listener.incoming().flatten() {
        let state = Arc::clone(&state);
        thread::spawn(move || serve(state, stream));
    }
}
