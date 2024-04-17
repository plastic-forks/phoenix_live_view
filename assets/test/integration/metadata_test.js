import { Socket } from 'phoenix'
import LiveSocket from 'phoenix_live_view/live_socket'

let stubViewPushEvent = (view, callback) => {
  view.pushEvent = (type, el, targetCtx, phxEvent, meta, opts = {}) => {
    return callback(type, el, targetCtx, phxEvent, meta, opts)
  }
}

let prepareLiveViewDOM = (document, rootId) => {
  document.body.innerHTML = `
    <div data-phx-session="abc123"
         data-phx-root-id="${rootId}"
         id="${rootId}">
      <label for="plus">Plus</label>
      <input id="plus" value="1" />
      <button id="btn" phx-click="inc_temperature">Inc Temperature</button>
    </div>
  `
}

describe('metadata', () => {
  beforeEach(() => {
    prepareLiveViewDOM(global.document, 'root')
  })

  test('is empty by default', () => {
    let liveSocket = new LiveSocket('/live', Socket)
    liveSocket.connect()
    let view = liveSocket.getViewByEl(document.getElementById('root'))
    let btn = view.el.querySelector('button')
    let meta = {}
    stubViewPushEvent(view, (type, el, target, targetCtx, phxEvent, metadata) => {
      meta = metadata
    })
    btn.dispatchEvent(new Event('click', { bubbles: true }))

    expect(meta).toEqual({})
  })

  test('can be user defined', () => {
    let liveSocket = new LiveSocket('/live', Socket, {
      metadata: {
        click: (e, el) => {
          return {
            id: el.id,
            altKey: e.altKey,
          }
        },
      },
    })
    liveSocket.connect()
    liveSocket.isConnected = () => true
    let view = liveSocket.getViewByEl(document.getElementById('root'))
    view.isConnected = () => true
    let btn = view.el.querySelector('button')
    let meta = {}
    stubViewPushEvent(view, (type, el, target, phxEvent, metadata, opts) => {
      meta = metadata
    })
    btn.dispatchEvent(new Event('click', { bubbles: true }))

    expect(meta).toEqual({
      id: 'btn',
      altKey: undefined,
    })
  })
})
