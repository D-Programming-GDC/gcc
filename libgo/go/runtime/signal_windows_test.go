// +build windows

package runtime_test

import (
	"bufio"
	"bytes"
	"fmt"
	"internal/testenv"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestVectoredHandlerDontCrashOnLibrary(t *testing.T) {
	if *flagQuick {
		t.Skip("-quick")
	}
	if runtime.GOARCH != "amd64" {
		t.Skip("this test can only run on windows/amd64")
	}
	testenv.MustHaveGoBuild(t)
	testenv.MustHaveExecPath(t, "gcc")
	testprog.Lock()
	defer testprog.Unlock()
	dir, err := os.MkdirTemp("", "go-build")
	if err != nil {
		t.Fatalf("failed to create temp directory: %v", err)
	}
	defer os.RemoveAll(dir)

	// build go dll
	dll := filepath.Join(dir, "testwinlib.dll")
	cmd := exec.Command(testenv.GoToolPath(t), "build", "-o", dll, "--buildmode", "c-shared", "testdata/testwinlib/main.go")
	out, err := testenv.CleanCmdEnv(cmd).CombinedOutput()
	if err != nil {
		t.Fatalf("failed to build go library: %s\n%s", err, out)
	}

	// build c program
	exe := filepath.Join(dir, "test.exe")
	cmd = exec.Command("gcc", "-L"+dir, "-I"+dir, "-ltestwinlib", "-o", exe, "testdata/testwinlib/main.c")
	out, err = testenv.CleanCmdEnv(cmd).CombinedOutput()
	if err != nil {
		t.Fatalf("failed to build c exe: %s\n%s", err, out)
	}

	// run test program
	cmd = exec.Command(exe)
	out, err = testenv.CleanCmdEnv(cmd).CombinedOutput()
	if err != nil {
		t.Fatalf("failure while running executable: %s\n%s", err, out)
	}
	expectedOutput := "exceptionCount: 1\ncontinueCount: 1\n"
	// cleaning output
	cleanedOut := strings.ReplaceAll(string(out), "\r\n", "\n")
	if cleanedOut != expectedOutput {
		t.Errorf("expected output %q, got %q", expectedOutput, cleanedOut)
	}
}

func sendCtrlBreak(pid int) error {
	kernel32, err := syscall.LoadDLL("kernel32.dll")
	if err != nil {
		return fmt.Errorf("LoadDLL: %v\n", err)
	}
	generateEvent, err := kernel32.FindProc("GenerateConsoleCtrlEvent")
	if err != nil {
		return fmt.Errorf("FindProc: %v\n", err)
	}
	result, _, err := generateEvent.Call(syscall.CTRL_BREAK_EVENT, uintptr(pid))
	if result == 0 {
		return fmt.Errorf("GenerateConsoleCtrlEvent: %v\n", err)
	}
	return nil
}

// TestCtrlHandler tests that Go can gracefully handle closing the console window.
// See https://golang.org/issues/41884.
func TestCtrlHandler(t *testing.T) {
	testenv.MustHaveGoBuild(t)
	t.Parallel()

	// build go program
	exe := filepath.Join(t.TempDir(), "test.exe")
	cmd := exec.Command(testenv.GoToolPath(t), "build", "-o", exe, "testdata/testwinsignal/main.go")
	out, err := testenv.CleanCmdEnv(cmd).CombinedOutput()
	if err != nil {
		t.Fatalf("failed to build go exe: %v\n%s", err, out)
	}

	// run test program
	cmd = exec.Command(exe)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	outPipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("Failed to create stdout pipe: %v", err)
	}
	outReader := bufio.NewReader(outPipe)

	// in a new command window
	const _CREATE_NEW_CONSOLE = 0x00000010
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: _CREATE_NEW_CONSOLE,
		HideWindow:    true,
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	defer func() {
		cmd.Process.Kill()
		cmd.Wait()
	}()

	// wait for child to be ready to receive signals
	if line, err := outReader.ReadString('\n'); err != nil {
		t.Fatalf("could not read stdout: %v", err)
	} else if strings.TrimSpace(line) != "ready" {
		t.Fatalf("unexpected message: %s", line)
	}

	// gracefully kill pid, this closes the command window
	if err := exec.Command("taskkill.exe", "/pid", strconv.Itoa(cmd.Process.Pid)).Run(); err != nil {
		t.Fatalf("failed to kill: %v", err)
	}

	// check child received, handled SIGTERM
	if line, err := outReader.ReadString('\n'); err != nil {
		t.Fatalf("could not read stdout: %v", err)
	} else if expected, got := syscall.SIGTERM.String(), strings.TrimSpace(line); expected != got {
		t.Fatalf("Expected '%s' got: %s", expected, got)
	}

	// check child exited gracefully, did not timeout
	if err := cmd.Wait(); err != nil {
		t.Fatalf("Program exited with error: %v\n%s", err, &stderr)
	}
}

// TestLibraryCtrlHandler tests that Go DLL allows calling program to handle console control events.
// See https://golang.org/issues/35965.
func TestLibraryCtrlHandler(t *testing.T) {
	if *flagQuick {
		t.Skip("-quick")
	}
	if runtime.GOARCH != "amd64" {
		t.Skip("this test can only run on windows/amd64")
	}
	testenv.MustHaveGoBuild(t)
	testenv.MustHaveExecPath(t, "gcc")
	testprog.Lock()
	defer testprog.Unlock()
	dir, err := os.MkdirTemp("", "go-build")
	if err != nil {
		t.Fatalf("failed to create temp directory: %v", err)
	}
	defer os.RemoveAll(dir)

	// build go dll
	dll := filepath.Join(dir, "dummy.dll")
	cmd := exec.Command(testenv.GoToolPath(t), "build", "-o", dll, "--buildmode", "c-shared", "testdata/testwinlibsignal/dummy.go")
	out, err := testenv.CleanCmdEnv(cmd).CombinedOutput()
	if err != nil {
		t.Fatalf("failed to build go library: %s\n%s", err, out)
	}

	// build c program
	exe := filepath.Join(dir, "test.exe")
	cmd = exec.Command("gcc", "-o", exe, "testdata/testwinlibsignal/main.c")
	out, err = testenv.CleanCmdEnv(cmd).CombinedOutput()
	if err != nil {
		t.Fatalf("failed to build c exe: %s\n%s", err, out)
	}

	// run test program
	cmd = exec.Command(exe)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	outPipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("Failed to create stdout pipe: %v", err)
	}
	outReader := bufio.NewReader(outPipe)

	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP,
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	errCh := make(chan error, 1)
	go func() {
		if line, err := outReader.ReadString('\n'); err != nil {
			errCh <- fmt.Errorf("could not read stdout: %v", err)
		} else if strings.TrimSpace(line) != "ready" {
			errCh <- fmt.Errorf("unexpected message: %v", line)
		} else {
			errCh <- sendCtrlBreak(cmd.Process.Pid)
		}
	}()

	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("Program exited with error: %v\n%s", err, &stderr)
	}
}
