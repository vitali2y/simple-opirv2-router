use nucleo_picker::{PickerOptions, render::StrRenderer};
use std::{
    env,
    io::{self, BufRead, IsTerminal},
    process,
    thread::spawn,
};

fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();

    // Parse fzf-compatible arguments
    let mut multi_select = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-m" | "--multi" => multi_select = true,
            _ => {}
        }
        i += 1;
    }

    // Configure picker with options
    let mut picker = PickerOptions::default().picker(StrRenderer);

    // Handle stdin input
    if !io::stdin().is_terminal() {
        let injector = picker.injector();
        spawn(move || {
            let stdin = io::stdin();
            for line in stdin.lines() {
                if let Ok(s) = line {
                    injector.push(s);
                }
            }
        });
    } else {
        eprintln!("Error: No input provided to joshuto-nucleo");
        process::exit(1);
    }

    // Run the picker
    match picker.pick()? {
        Some(selection) => {
            println!("{}", selection);
            process::exit(0);
        }
        None => {
            process::exit(130); // fzf exit code for cancel
        }
    }
}
